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
 */
internal class ShapeMaskedImage {

    private var painter: ShapeMaskPainter? = null
    private var output: Bitmap? = null

    private var source: Bitmap? = null
    private var sourceBytes: ByteArray? = null
    private var outputBytes: ByteArray? = null
    private var maskBytes: ByteArray? = null

    private var shownSource: Bitmap? = null
    private var shownState: ShapeMaskState? = null

    /** [image] shown through [state], in a bitmap this object keeps and reuses. */
    fun masked(image: Bitmap, state: ShapeMaskState): Bitmap {
        val current = output
        if (current != null && image === shownSource && state == shownState) return current

        val width = image.width
        val height = image.height
        val painter = painter?.takeIf { it.width == width && it.height == height }
            ?: ShapeMaskPainter(width, height).also {
                painter?.recycle()
                painter = it
            }
        painter.paint(state)

        val byteCount = width * height * 4
        if (image !== source) {
            val bytes = sourceBytes?.takeIf { it.size == byteCount } ?: ByteArray(byteCount)
            val buffer = ByteBuffer.wrap(bytes)
            image.copyPixelsToBuffer(buffer)
            sourceBytes = bytes
            source = image
        }
        val mask = maskBytes?.takeIf { it.size == byteCount } ?: ByteArray(byteCount)
        painter.copyRgba(mask)
        maskBytes = mask

        val out = outputBytes?.takeIf { it.size == byteCount } ?: ByteArray(byteCount)
        maskStraightAlpha(sourceBytes!!, mask, out, byteCount)
        outputBytes = out

        val target = current?.takeIf { it.width == width && it.height == height }
            ?: Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
                current?.recycle()
                output = it
            }
        target.copyPixelsFromBuffer(ByteBuffer.wrap(out))

        shownSource = image
        shownState = state
        return target
    }

    fun recycle() {
        painter?.recycle()
        painter = null
        output?.recycle()
        output = null
        source = null
        shownSource = null
    }
}

/**
 * Writes [image], RGBA bytes with straight alpha, into [out] with each pixel's
 * alpha scaled by the alpha of the same pixel of [mask], RGBA bytes too.
 * Colors pass through untouched, as straight alpha keeps them.
 */
internal fun maskStraightAlpha(image: ByteArray, mask: ByteArray, out: ByteArray, byteCount: Int) {
    var i = 0
    while (i < byteCount) {
        out[i] = image[i]
        out[i + 1] = image[i + 1]
        out[i + 2] = image[i + 2]
        val alpha = image[i + 3].toInt() and 0xFF
        val matte = mask[i + 3].toInt() and 0xFF
        // Rounded, so a fully shown pixel keeps its alpha exactly.
        out[i + 3] = ((alpha * matte + 127) / 255).toByte()
        i += 4
    }
}
