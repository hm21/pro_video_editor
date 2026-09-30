package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.VideoEffectFrame
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * The per-pixel specification of a [VideoEffectFrame], on the CPU.
 *
 * Three renderers implement it: the GLES shader in [VideoEffectGlEffect], the
 * Core Image stage in `ApplyVideoEffect.swift`, and the Flutter preview shader
 * `shaders/video_effect.frag`. This object is the version the JVM tests can
 * run; `VideoEffectMathTest` pins it with a golden table that the Swift test
 * checks Core Image against. **Change all four together.**
 *
 * Coordinates count whole pixels from the top-left corner. For every output
 * pixel `(x, y)`, in this order:
 *
 * 1. **Pixelate**: blocks of `toPixels(pixelSize, width)` pixels (off below 2),
 *    starting at the top-left corner, each take the pixel at
 *    `blockStart + block / 2` (integer division).
 * 2. **Bands**: in the rows of the first band that covers `y`, content moves
 *    right by `toPixels(shift, width)`.
 * 3. **Channel split**: red is read `toPixels(rgbShift, width)` pixels to the
 *    right (so it moves left), blue as far to the left, green in place. Every
 *    read past an edge repeats the edge pixel, at each of these steps.
 * 4. **Scanlines**: with a period of `max(2, toPixels(scanlinePeriod, height))`
 *    rows, the rows where `(y % period) * 2 >= period` are multiplied by
 *    `1 - scanlines`.
 * 5. **Noise**: `(noiseAt(u, v) - 0.5) * noise` is added to red, green and
 *    blue, where `u = (x / cell + noiseOffsetX) % 128` and likewise for `v`,
 *    with a cell of `max(1, toPixels(noiseCellSize, height))` pixels.
 * 6. **Tones**, in this order: `rgb = mix(rgb, S * rgb, sepia)` with the
 *    [SEPIA] matrix, `rgb *= 1 + brightness`, `rgb += invert * (1 - 2 * rgb)`,
 *    `rgb += flash * (1 - rgb)`.
 * 7. **Vignette**: with `dx = (2x + 1) / width - 1`, `dy` likewise,
 *    `d = sqrt((dx² + dy²) / 2)`, `r = clamp(vignetteRadius, 0, 0.99)` and
 *    `t = clamp((d - r) / (1 - r), 0, 1)`, rgb is multiplied by
 *    `1 - vignette * t²`.
 *
 * The colors are clamped to 0..1 after step 5 and after step 6, not between
 * the tones. Alpha is the unshifted pixel's.
 */
object VideoEffectMath {

    /** Edge length of the repeating noise tile, in cells. */
    const val NOISE_TILE = 128

    /** The sepia tone matrix, row by row: red, green and blue out of `(r, g, b)`. */
    val SEPIA = arrayOf(
        doubleArrayOf(0.393, 0.769, 0.189),
        doubleArrayOf(0.349, 0.686, 0.168),
        doubleArrayOf(0.272, 0.534, 0.131),
    )

    /**
     * The vignette's factor for pixel ([x], [y]) of a [width] by [height]
     * frame: `1 - amount * t²`, see step 7.
     */
    fun vignetteFactor(x: Int, y: Int, width: Int, height: Int, amount: Double, radius: Double): Double {
        val r = radius.coerceIn(0.0, 0.99)
        val dx = (2.0 * x + 1.0) / width - 1.0
        val dy = (2.0 * y + 1.0) / height - 1.0
        val t = ((sqrt((dx * dx + dy * dy) / 2.0) - r) / (1.0 - r)).coerceIn(0.0, 1.0)
        return 1.0 - amount * t * t
    }

    /** Rounds a fraction of [size] to whole pixels: `floor(f * size + 0.5)`. */
    fun toPixels(fraction: Double, size: Int): Int = floor(fraction * size + 0.5).toInt()

    /** The noise value, in `[0, 1)`, of a cell of the noise tile. */
    fun noiseAt(u: Int, v: Int): Double {
        var a = (u * 37 + v * 101 + 13) % 251
        a = (a * a + u * 7 + 17) % 251
        a = (a * a + v * 3 + 29) % 251
        return a / 251.0
    }

    /**
     * Applies [frame] to an image of opaque `0xAARRGGBB` [pixels], first row at
     * the top, and returns the result in the same layout.
     */
    fun apply(pixels: IntArray, width: Int, height: Int, frame: VideoEffectFrame): IntArray {
        val block = toPixels(frame.pixelSize, width)
        val split = toPixels(frame.rgbShift, width)
        val scanPeriod = maxOf(2, toPixels(frame.scanlinePeriod, height))
        val cell = maxOf(1, toPixels(frame.noiseCellSize, height))
        val bands = frame.bands.take(VideoEffectFrame.MAX_BANDS).map {
            Triple(toPixels(it.top, height), toPixels(it.bottom, height), toPixels(it.shift, width))
        }

        fun pixelated(x: Int, y: Int): Int {
            var sx = x.coerceIn(0, width - 1)
            var sy = y
            if (block >= 2) {
                sx = sx / block * block + block / 2
                sy = sy / block * block + block / 2
            }
            return pixels[sy.coerceIn(0, height - 1) * width + sx.coerceIn(0, width - 1)]
        }

        fun banded(x: Int, y: Int, shift: Int): Int {
            val sx = x.coerceIn(0, width - 1)
            return pixelated((sx - shift).coerceIn(0, width - 1), y)
        }

        val out = IntArray(width * height)
        for (y in 0 until height) {
            val shift = bands.firstOrNull { y >= it.first && y < it.second }?.third ?: 0
            val dark = frame.scanlines > 0.0 && (y % scanPeriod) * 2 >= scanPeriod
            for (x in 0 until width) {
                val center = banded(x, y, shift)
                var r = ((banded(x + split, y, shift) shr 16) and 0xFF) / 255.0
                var g = ((center shr 8) and 0xFF) / 255.0
                var b = (banded(x - split, y, shift) and 0xFF) / 255.0
                if (dark) {
                    val keep = 1.0 - frame.scanlines
                    r *= keep; g *= keep; b *= keep
                }
                if (frame.noise > 0.0) {
                    val u = (x / cell + frame.noiseOffsetX) % NOISE_TILE
                    val v = (y / cell + frame.noiseOffsetY) % NOISE_TILE
                    val grain = (noiseAt(u, v) - 0.5) * frame.noise
                    r += grain; g += grain; b += grain
                }
                r = r.coerceIn(0.0, 1.0); g = g.coerceIn(0.0, 1.0); b = b.coerceIn(0.0, 1.0)
                if (frame.sepia > 0.0) {
                    val s = frame.sepia
                    val sr = SEPIA[0][0] * r + SEPIA[0][1] * g + SEPIA[0][2] * b
                    val sg = SEPIA[1][0] * r + SEPIA[1][1] * g + SEPIA[1][2] * b
                    val sb = SEPIA[2][0] * r + SEPIA[2][1] * g + SEPIA[2][2] * b
                    r += (sr - r) * s; g += (sg - g) * s; b += (sb - b) * s
                }
                val gain = 1.0 + frame.brightness
                r *= gain; g *= gain; b *= gain
                r += frame.invert * (1.0 - 2.0 * r)
                g += frame.invert * (1.0 - 2.0 * g)
                b += frame.invert * (1.0 - 2.0 * b)
                r += frame.flash * (1.0 - r)
                g += frame.flash * (1.0 - g)
                b += frame.flash * (1.0 - b)
                r = r.coerceIn(0.0, 1.0); g = g.coerceIn(0.0, 1.0); b = b.coerceIn(0.0, 1.0)
                if (frame.vignette > 0.0) {
                    val keep = vignetteFactor(x, y, width, height, frame.vignette, frame.vignetteRadius)
                    r *= keep; g *= keep; b *= keep
                }
                out[y * width + x] = (center and 0xFF000000.toInt()) or
                    (toByte(r) shl 16) or (toByte(g) shl 8) or toByte(b)
            }
        }
        return out
    }

    private fun toByte(value: Double): Int = (value.coerceIn(0.0, 1.0) * 255.0).roundToInt()
}
