package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.ChromaKeyConfig
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * The chroma-key formula, in plain Kotlin.
 *
 * This is the single spec both platforms implement. The GPU actually runs it
 * inside [ChromaKeyEffect]'s fragment shader; Apple bakes the very same math
 * into a Core Image color cube (`ApplyChromaKey.swift`). This class exists so
 * the formula can be unit-tested without a GL context, and so the Kotlin and
 * Swift tests can assert the *same* golden table — a drift in either
 * implementation then fails a fast test instead of an emulator run.
 *
 * Keep this file, the fragment shader and `chromaKeyed(r:g:b:_:)` in Swift in
 * lockstep. All values are gamma-encoded, non-color-managed RGB in `0..1`.
 */
object ChromaKeyMath {

    /** BT.601 luma of a gamma-encoded RGB triple. */
    fun luma(r: Double, g: Double, b: Double): Double =
        0.299 * r + 0.587 * g + 0.114 * b

    /**
     * BT.601 chroma projection of a gamma-encoded RGB triple, as `(Cb, Cr)`.
     *
     * The keyer measures distance in this plane. Note that this is a position,
     * not a pure hue: Cb and Cr scale with brightness, so a dimly lit patch of
     * the screen sits closer to neutral and further from the key point. The
     * default `similarity` of 0.20 covers roughly 40%..100% of the screen's
     * reference brightness. Same behaviour as FFmpeg's `chromakey` and OBS.
     */
    fun chroma(r: Double, g: Double, b: Double): DoubleArray = doubleArrayOf(
        -0.168736 * r - 0.331264 * g + 0.5 * b,
        0.5 * r - 0.418688 * g - 0.081312 * b,
    )

    /** Hermite smoothstep, matching GLSL's `smoothstep`. */
    fun smoothstep(edge0: Double, edge1: Double, x: Double): Double {
        if (edge1 <= edge0) return if (x < edge0) 0.0 else 1.0
        val t = ((x - edge0) / (edge1 - edge0)).coerceIn(0.0, 1.0)
        return t * t * (3 - 2 * t)
    }

    /**
     * Evaluates the key for one pixel.
     *
     * @return `[r, g, b, alpha]` with **straight** (not premultiplied) alpha,
     *  which is the convention Media3 uses end to end.
     */
    fun evaluate(r: Double, g: Double, b: Double, config: ChromaKeyConfig): DoubleArray {
        val c = chroma(r, g, b)
        val dCb = c[0] - config.keyCb
        val dCr = c[1] - config.keyCr
        val distance = sqrt(dCb * dCb + dCr * dCr)

        // max() keeps a zero-width ramp from dividing by zero, matching the
        // shader's `max(uSmoothness, 1e-4)`.
        val alpha = smoothstep(
            config.similarity,
            config.similarity + max(config.smoothness, 1e-4),
            distance,
        )

        // Spill suppression. `projection` is how far the pixel leans toward the
        // key hue; only pixels leaning toward it (> 0) are touched, so a
        // complementary color is never desaturated. Y stays untouched, so a
        // despilled pixel never darkens.
        val projection = c[0] * config.keyDirCb + c[1] * config.keyDirCr
        if (config.spill <= 0.0 || projection <= 0.0) {
            return doubleArrayOf(r, g, b, alpha)
        }

        val y = luma(r, g, b)
        val cb = c[0] - config.keyDirCb * projection * config.spill
        val cr = c[1] - config.keyDirCr * projection * config.spill

        return doubleArrayOf(
            clamp01(y + 1.402 * cr),
            clamp01(y - 0.344136 * cb - 0.714136 * cr),
            clamp01(y + 1.772 * cb),
            alpha,
        )
    }

    private fun clamp01(v: Double): Double = min(max(v, 0.0), 1.0)
}
