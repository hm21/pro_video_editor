package ch.waio.pro_video_editor.src.features.frames

import android.graphics.Bitmap
import java.nio.ByteBuffer

/**
 * Output format that makes [ch.waio.pro_video_editor.src.features.thumbnail.ThumbnailGenerator]
 * deliver raw luma instead of a compressed image. Internal to
 * [LumaFrameExtractor]; not a format callers can request.
 */
internal const val LUMA_FORMAT = "luma"

/** A decoded luma frame: [width] × [height] row-major bytes in [luma]. */
internal class LumaPayload(val width: Int, val height: Int, val luma: ByteArray)

/**
 * Converts [bitmap] to row-major 8-bit luma (BT.601 weights), prefixed with
 * its width and height as two big-endian ints. The size travels with the
 * bytes because the extraction strategies scale with slightly different
 * rounding.
 */
internal fun lumaWithHeader(bitmap: Bitmap): ByteArray {
    val width = bitmap.width
    val height = bitmap.height
    val pixels = IntArray(width * height)
    bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
    val out = ByteArray(HEADER_BYTES + pixels.size)
    ByteBuffer.wrap(out).putInt(width).putInt(height)
    for (i in pixels.indices) {
        val p = pixels[i]
        val r = (p shr 16) and 0xFF
        val g = (p shr 8) and 0xFF
        val b = p and 0xFF
        out[HEADER_BYTES + i] = ((r * 77 + g * 150 + b * 29) shr 8).toByte()
    }
    return out
}

/**
 * This frame resampled bilinearly to [newWidth] × [newHeight]; the frame
 * itself when it already has that size.
 */
internal fun LumaPayload.resized(newWidth: Int, newHeight: Int): LumaPayload {
    if (newWidth == width && newHeight == height) return this
    val out = ByteArray(newWidth * newHeight)
    val scaleX = width.toFloat() / newWidth
    val scaleY = height.toFloat() / newHeight
    for (y in 0 until newHeight) {
        val fy = ((y + 0.5f) * scaleY - 0.5f).coerceIn(0f, (height - 1).toFloat())
        val y0 = fy.toInt()
        val y1 = minOf(y0 + 1, height - 1)
        val wy = fy - y0
        for (x in 0 until newWidth) {
            val fx = ((x + 0.5f) * scaleX - 0.5f).coerceIn(0f, (width - 1).toFloat())
            val x0 = fx.toInt()
            val x1 = minOf(x0 + 1, width - 1)
            val wx = fx - x0
            val top = luma.at(y0 * width + x0) * (1 - wx) + luma.at(y0 * width + x1) * wx
            val bottom = luma.at(y1 * width + x0) * (1 - wx) + luma.at(y1 * width + x1) * wx
            out[y * newWidth + x] = (top * (1 - wy) + bottom * wy + 0.5f).toInt().toByte()
        }
    }
    return LumaPayload(newWidth, newHeight, out)
}

private fun ByteArray.at(i: Int): Float = (this[i].toInt() and 0xFF).toFloat()

/** Reads a payload written by [lumaWithHeader]. */
internal fun parseLumaPayload(bytes: ByteArray): LumaPayload {
    require(bytes.size >= HEADER_BYTES) { "Luma payload is truncated" }
    val header = ByteBuffer.wrap(bytes, 0, HEADER_BYTES)
    val width = header.int
    val height = header.int
    require(width > 0 && height > 0 && bytes.size - HEADER_BYTES == width * height) {
        "Luma payload of ${bytes.size} bytes does not hold a ${width}x$height frame"
    }
    return LumaPayload(width, height, bytes.copyOfRange(HEADER_BYTES, bytes.size))
}

private const val HEADER_BYTES = 8
