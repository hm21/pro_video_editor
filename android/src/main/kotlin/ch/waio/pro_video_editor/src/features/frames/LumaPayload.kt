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
