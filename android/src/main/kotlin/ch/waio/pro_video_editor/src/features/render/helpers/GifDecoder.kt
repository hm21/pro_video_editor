package ch.waio.pro_video_editor.src.features.render.helpers

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Movie

/**
 * Decodes an animated GIF into a list of bitmap frames.
 *
 * Uses the platform [Movie] decoder (available since API 1, unlike
 * `ImageDecoder` which needs API 28) and samples it at a fixed cadence over its
 * total duration. Fixed-rate sampling approximates the GIF's per-frame delays
 * closely enough for an overlay while keeping the decoder tiny and dependency
 * free; [Movie] internally handles frame disposal/compositing.
 */
object GifDecoder {
    /** Sampling rate used to turn the GIF timeline into discrete frames. */
    private const val SAMPLE_FPS = 25

    /** Upper bound on decoded frames to keep memory use bounded. */
    private const val MAX_FRAMES = 300

    /** A single decoded GIF frame and how long it is shown. */
    data class GifFrame(val bitmap: Bitmap, val durationUs: Long)

    /**
     * How many leading bytes [isGif] needs, so a caller holding a file can
     * check the signature without reading the whole image.
     */
    const val MAGIC_LENGTH = 3

    /** Returns true when [bytes] start with the `GIF` signature. */
    fun isGif(bytes: ByteArray): Boolean =
        bytes.size >= 3 &&
            bytes[0] == 'G'.code.toByte() &&
            bytes[1] == 'I'.code.toByte() &&
            bytes[2] == 'F'.code.toByte()

    /**
     * Decodes [bytes] into animated frames, or returns null when the data is
     * not a GIF or has no animation (single frame / zero duration). Callers
     * should fall back to the regular static-image path in that case.
     */
    @Suppress("DEPRECATION")
    fun decode(bytes: ByteArray): List<GifFrame>? {
        if (!isGif(bytes)) return null

        val movie = try {
            Movie.decodeByteArray(bytes, 0, bytes.size)
        } catch (e: Exception) {
            null
        } ?: return null

        val durationMs = movie.duration()
        val width = movie.width()
        val height = movie.height()
        // duration == 0 means Movie can't separate frames by time (e.g. all
        // delays are 0); treat it as a static image.
        if (durationMs <= 0 || width <= 0 || height <= 0) return null

        val frameCount =
            (durationMs.toLong() * SAMPLE_FPS / 1000L).toInt().coerceIn(2, MAX_FRAMES)
        val frameDurationUs = durationMs * 1000L / frameCount

        val frames = ArrayList<GifFrame>(frameCount)
        for (i in 0 until frameCount) {
            val timeMs = (i.toLong() * durationMs / frameCount).toInt()
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            movie.setTime(timeMs)
            movie.draw(canvas, 0f, 0f)
            frames.add(GifFrame(bitmap, frameDurationUs))
        }
        return frames
    }
}
