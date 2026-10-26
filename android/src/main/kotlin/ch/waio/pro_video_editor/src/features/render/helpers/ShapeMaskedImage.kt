package ch.waio.pro_video_editor.src.features.render.helpers

import android.graphics.Bitmap
import ch.waio.pro_video_editor.src.features.render.models.ShapeMaskState
import java.nio.ByteBuffer

/**
 * An overlay image shown through a shape mask that may change from frame to
 * frame: [masked] returns the image with every pixel's alpha scaled by the
 * mask's there.
 *
 * Overlay images hold **straight** alpha (see `unpremultiplyAlpha`), which a
 * `Canvas` cannot draw, so the alpha is scaled byte by byte instead and the
 * colors pass through. The result is written into one bitmap that is reused,
 * which Media3 uploads again whenever its generation changes, and is only
 * redone when the image or the mask changed since the last frame.
 *
 * Holds one image-sized buffer on the Java heap, which the image is copied
 * into and masked in place, and the mask as alpha only: a full-frame overlay
 * is tens of megabytes, and the overlay path is where a render runs out of
 * memory.
 */
internal class ShapeMaskedImage {

    private var painter: ShapeMaskPainter? = null
    private var output: Bitmap? = null

    private var pixels: ByteArray? = null
    private var matte: ByteArray? = null

    private var shownSource: Bitmap? = null
    private var shownState: ShapeMaskState? = null

    /** [image] shown through [state], in a bitmap this object keeps and reuses. */
    fun masked(image: Bitmap, state: ShapeMaskState): Bitmap {
        val current = output
        if (current != null && image === shownSource && state == shownState) return current

        val width = image.width
        val height = image.height
        val painter = painter?.takeIf { it.width == width && it.height == height }
            ?: ShapeMaskPainter(width, height, Bitmap.Config.ALPHA_8).also {
                painter?.recycle()
                painter = it
                matte = null
            }
        val matteBytes = painter.bitmap.byteCount
        val matte = matte?.takeIf { it.size == matteBytes }
        if (painter.paint(state) || matte == null) {
            val bytes = matte ?: ByteArray(matteBytes)
            painter.copyPixels(bytes)
            this.matte = bytes
        }

        val byteCount = width * height * 4
        val pixels = pixels?.takeIf { it.size == byteCount } ?: ByteArray(byteCount)
        image.copyPixelsToBuffer(ByteBuffer.wrap(pixels))
        maskStraightAlpha(pixels, this.matte!!, width, height, painter.bitmap.rowBytes)
        this.pixels = pixels

        val target = current?.takeIf { it.width == width && it.height == height }
            ?: Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
                current?.recycle()
                output = it
            }
        target.copyPixelsFromBuffer(ByteBuffer.wrap(pixels))

        shownSource = image
        shownState = state
        return target
    }

    fun recycle() {
        painter?.recycle()
        painter = null
        output?.recycle()
        output = null
        pixels = null
        matte = null
        shownSource = null
    }
}

/**
 * Scales the alpha of every pixel of [pixels], [width] x [height] RGBA bytes
 * with straight alpha, by the alpha of the same pixel of [matte], one byte per
 * pixel and its rows [matteRowBytes] apart. Colors pass through untouched, as
 * straight alpha keeps them.
 */
internal fun maskStraightAlpha(
    pixels: ByteArray,
    matte: ByteArray,
    width: Int,
    height: Int,
    matteRowBytes: Int,
) {
    for (y in 0 until height) {
        var i = y * width * 4 + 3
        var m = y * matteRowBytes
        repeat(width) {
            val alpha = pixels[i].toInt() and 0xFF
            val shown = matte[m].toInt() and 0xFF
            // Rounded, so a fully shown pixel keeps its alpha exactly.
            pixels[i] = ((alpha * shown + 127) / 255).toByte()
            i += 4
            m++
        }
    }
}
