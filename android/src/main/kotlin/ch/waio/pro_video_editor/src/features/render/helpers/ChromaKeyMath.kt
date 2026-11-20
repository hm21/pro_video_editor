package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.ChromaKeyConfig
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * The chroma-key formula, in plain Kotlin.
 *
 * This is the single spec both platforms implement. The GPU actually runs it
 * inside [ChromaKeyEffect]'s fragment shader; Apple runs the very same math in
 * a Metal kernel (`ApplyChromaKey.swift`). This class exists so the formula can
 * be unit-tested without a GL context, and so the Kotlin and Swift tests can
 * assert the *same* golden tables — a drift in either implementation then
 * fails a fast test instead of an emulator run.
 *
 * The matte is not taken from one pixel alone. Video stores colour at half the
 * resolution of brightness, so a per-pixel key steps along an edge and
 * flickers with compression noise. Both renderers evaluate [distance] on the
 * 3×3 neighbourhood of each pixel and average the nine with
 * [neighbourhoodDistance] before the smoothstep; despill still reads the
 * centre pixel alone.
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
     * The keyer measures distance in this plane, plus brightness for a
     * neutral key (see [lumaWeight]). Note that this is a position,
     * not a pure hue: Cb and Cr scale with brightness, so a dimly lit patch of
     * the screen sits closer to neutral and further from the key point. The
     * default `similarity` of 0.20 covers roughly 40%..100% of the screen's
     * reference brightness. Same behaviour as FFmpeg's `chromakey` and OBS.
     */
    fun chroma(r: Double, g: Double, b: Double): DoubleArray = doubleArrayOf(
        -0.168736 * r - 0.331264 * g + 0.5 * b,
        0.5 * r - 0.418688 * g - 0.081312 * b,
    )

    /** Below this key chroma magnitude, brightness counts fully in the matte. */
    const val LUMA_WEIGHT_FULL_BELOW = 0.04

    /** Above this key chroma magnitude, brightness does not count at all. */
    const val LUMA_WEIGHT_NONE_ABOVE = 0.10

    /**
     * How much the brightness difference counts toward the matte distance, for
     * a key at chroma `(cb, cr)`.
     *
     * A saturated key (a green or blue screen sits near 0.33) gets `0`, so it
     * keys on chroma alone exactly as before: that is what lets a shadow on the
     * screen, which changes brightness but not hue, stay under the key. A
     * neutral key gets `1`. All neutrals share the chroma origin, so without
     * brightness a white key would also remove black and every gray. In between
     * the weight ramps smoothly, so a pale wall is neither.
     */
    fun lumaWeight(cb: Double, cr: Double): Double =
        1.0 - smoothstep(LUMA_WEIGHT_FULL_BELOW, LUMA_WEIGHT_NONE_ABOVE, sqrt(cb * cb + cr * cr))

    /** Hermite smoothstep, matching GLSL's `smoothstep`. */
    fun smoothstep(edge0: Double, edge1: Double, x: Double): Double {
        if (edge1 <= edge0) return if (x < edge0) 0.0 else 1.0
        val t = ((x - edge0) / (edge1 - edge0)).coerceIn(0.0, 1.0)
        return t * t * (3 - 2 * t)
    }

    /**
     * The key distance of one pixel: chroma, plus brightness weighted by how
     * neutral the key is.
     */
    fun distance(r: Double, g: Double, b: Double, config: ChromaKeyConfig): Double {
        val c = chroma(r, g, b)
        val y = luma(r, g, b)
        val dCb = c[0] - config.keyCb
        val dCr = c[1] - config.keyCr
        val dY = (y - config.keyLuma) * config.lumaWeight
        return sqrt(dCb * dCb + dCr * dCr + dY * dY)
    }

    /**
     * Averages the key distances of a pixel's 3×3 neighbourhood, given
     * row-major (NW, N, NE, W, C, E, SW, S, SE), into the distance the matte
     * is ramped on.
     *
     * The binomial weights smooth the steps that half-resolution colour leaves
     * along an edge and the flicker of compression noise. A uniform
     * neighbourhood returns its own distance, so a flat area keys exactly as a
     * single pixel would. The renderers clamp the neighbourhood to the frame
     * edge.
     *
     * The matte is deliberately not shrunk as well: a one-pixel hair strand
     * looks to a 3×3 neighbourhood exactly like the screen-coloured fringe of
     * an edge, so any shrink deletes both. The fringe's tint is despill's job.
     */
    fun neighbourhoodDistance(taps: DoubleArray): Double {
        require(taps.size == 9) { "Expected 9 taps, got ${taps.size}" }
        return (
            4 * taps[4] +
                2 * (taps[1] + taps[3] + taps[5] + taps[7]) +
                taps[0] + taps[2] + taps[6] + taps[8]
            ) / 16
    }

    /**
     * The matte alpha for a key distance, ramped by smoothstep from
     * `similarity` over `smoothness`.
     */
    fun matte(distance: Double, config: ChromaKeyConfig): Double =
        // max() keeps a zero-width ramp from dividing by zero, matching the
        // shader's `max(uSmoothness, 1e-4)`.
        smoothstep(
            config.similarity,
            config.similarity + max(config.smoothness, 1e-4),
            distance,
        )

    /**
     * Evaluates the key for one pixel inside an area of its own colour.
     *
     * The renderers combine the [distance] of nine pixels instead (see
     * [neighbourhoodDistance]); over a flat area the two agree.
     *
     * @return `[r, g, b, alpha]` with **straight** (not premultiplied) alpha,
     *  which is the convention Media3 uses end to end.
     */
    fun evaluate(r: Double, g: Double, b: Double, config: ChromaKeyConfig): DoubleArray {
        val c = chroma(r, g, b)
        val y = luma(r, g, b)
        val alpha = matte(distance(r, g, b, config), config)

        // Spill suppression. `projection` is how far the pixel leans toward the
        // key hue; only pixels leaning toward it (> 0) are touched, so a
        // complementary color is never desaturated. Y stays untouched, so a
        // despilled pixel never darkens. The strength fades out with the luma
        // weight, so a neutral key does not despill at all.
        val spill = config.effectiveSpill
        val projection = c[0] * config.keyDirCb + c[1] * config.keyDirCr
        if (spill <= 0.0 || projection <= 0.0) {
            return doubleArrayOf(r, g, b, alpha)
        }

        val cb = c[0] - config.keyDirCb * projection * spill
        val cr = c[1] - config.keyDirCr * projection * spill

        return doubleArrayOf(
            clamp01(y + 1.402 * cr),
            clamp01(y - 0.344136 * cb - 0.714136 * cr),
            clamp01(y + 1.772 * cb),
            alpha,
        )
    }

    private fun clamp01(v: Double): Double = min(max(v, 0.0), 1.0)
}
