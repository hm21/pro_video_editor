package ch.waio.pro_video_editor.src.features.render.helpers

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import androidx.media3.common.OverlaySettings
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import ch.waio.pro_video_editor.src.features.render.models.LayerAudioVisualizerConfig
import java.nio.ByteBuffer

/**
 * An image layer that draws an audio visualizer instead of its image, redrawn
 * for every frame from the levels at that frame's time.
 *
 * [placement] is the overlay an image of [target]'s size would have been, and
 * places, animates and fades this one the same way. [target] is the raster the
 * visualizer is drawn into: the layer's box of [boxWidth] x [boxHeight]
 * composition pixels, rastered at `1 / rasterScale` of that and turned by
 * [rotationDegrees] about its center, exactly as `prepareOverlay` rasters and
 * turns an image.
 *
 * Media3 uploads the bitmap again whenever its generation changes, which
 * every redraw does.
 */
@UnstableApi
internal class AudioVisualizerOverlay(
    private val placement: BitmapOverlay,
    private val target: Bitmap,
    private val visualizer: LayerAudioVisualizerConfig,
    private val boxWidth: Float,
    private val boxHeight: Float,
    private val rotationDegrees: Float,
    private val rasterScaleX: Float,
    private val rasterScaleY: Float,
) : BitmapOverlay() {

    private val canvas = Canvas(target)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = visualizer.color
    }
    private val levels = FloatArray(visualizer.bandCount)
    private val rect = RectF()
    private val path = Path()

    /**
     * The frame [target] was last drawn for. Media3 reads the bitmap more than
     * once per frame, for its size and for its texture.
     */
    private var drawnAtUs: Long? = null

    override fun getBitmap(presentationTimeUs: Long): Bitmap {
        if (drawnAtUs != presentationTimeUs) {
            draw(presentationTimeUs)
            drawnAtUs = presentationTimeUs
        }
        return target
    }

    override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings =
        placement.getOverlaySettings(presentationTimeUs)

    override fun configure(videoSize: Size) {
        super.configure(videoSize)
        placement.configure(videoSize)
    }

    private fun draw(timeUs: Long) {
        visualizer.levelsAt(timeUs, levels)
        target.eraseColor(Color.TRANSPARENT)
        canvas.save()
        canvas.translate(target.width / 2f, target.height / 2f)
        canvas.rotate(rotationDegrees)
        canvas.scale(1f / rasterScaleX, 1f / rasterScaleY)
        canvas.translate(-boxWidth / 2f, -boxHeight / 2f)
        drawShapes(
            audioVisualizerShapes(
                visualizer.style, boxWidth.toDouble(), boxHeight.toDouble(), levels,
                visualizer.barFill
            )
        )
        canvas.restore()

        // Media3's overlay shader multiplies by alpha itself; see
        // unpremultiplyAlpha.
        val pixels = scratch(target.byteCount)
        target.copyPixelsToBuffer(pixels)
        unpremultiplyInPlace(pixels, target.byteCount)
        pixels.rewind()
        target.copyPixelsFromBuffer(pixels)
    }

    private fun drawShapes(shapes: AudioVisualizerShapes) {
        for (bar in shapes.bars) {
            rect.set(bar.left.toFloat(), bar.top.toFloat(), bar.right.toFloat(), bar.bottom.toFloat())
            val radius = bar.radius.toFloat()
            if (bar.rotation == 0.0 && bar.pivotX == 0.0 && bar.pivotY == 0.0) {
                canvas.drawRoundRect(rect, radius, radius, paint)
                continue
            }
            canvas.save()
            canvas.translate(bar.pivotX.toFloat(), bar.pivotY.toFloat())
            canvas.rotate(Math.toDegrees(bar.rotation).toFloat())
            canvas.drawRoundRect(rect, radius, radius, paint)
            canvas.restore()
        }
        val wave = shapes.wave ?: return
        path.reset()
        path.moveTo(wave[0].toFloat(), wave[1].toFloat())
        var i = 2
        while (i + 5 < wave.size) {
            path.cubicTo(
                wave[i].toFloat(), wave[i + 1].toFloat(),
                wave[i + 2].toFloat(), wave[i + 3].toFloat(),
                wave[i + 4].toFloat(), wave[i + 5].toFloat(),
            )
            i += 6
        }
        path.close()
        canvas.drawPath(path, paint)
    }

    private companion object {
        /**
         * The pixels of a raster, for dividing the alpha back out after a
         * redraw: one buffer per GL thread, shared by every visualizer drawn
         * on it. Image layers are built for every clip up front, so a buffer
         * per overlay would hold a raster's worth of memory per clip for the
         * whole export, while only one is ever drawn at a time.
         */
        private val pixelBuffer = ThreadLocal<ByteBuffer>()

        /** A buffer of at least [bytes], cleared for writing from the start. */
        fun scratch(bytes: Int): ByteBuffer {
            val held = pixelBuffer.get()
            val buffer = if (held != null && held.capacity() >= bytes) held
                else ByteBuffer.allocateDirect(bytes).also { pixelBuffer.set(it) }
            buffer.clear()
            return buffer
        }
    }
}
