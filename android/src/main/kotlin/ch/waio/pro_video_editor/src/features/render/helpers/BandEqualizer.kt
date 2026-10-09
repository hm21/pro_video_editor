package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.EqualizerBand
import ch.waio.pro_video_editor.src.features.render.models.EqualizerBandType
import ch.waio.pro_video_editor.src.features.render.models.EqualizerConfig
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Raises or lowers parts of interleaved PCM through the [EqualizerConfig.bands],
 * one second-order section per band, in band order.
 *
 * The sections are the low shelf, peak and high shelf of Robert
 * Bristow-Johnson's Audio EQ Cookbook. A shelf has a slope of 1, the steepest
 * that does not overshoot: half the gain at the corner, all of it an octave or
 * two beyond. A peak has the band's Q. Each channel keeps its own filter
 * state, in double precision, in transposed direct form II; a band without
 * gain is left out.
 *
 * `divine_video_player` carries a twin of this file for the editor preview,
 * and the Swift twin in this plugin renders the same on Apple platforms: all
 * three compute the same coefficients from the same formulas, so a preview
 * sounds like the export.
 *
 * @param config The bands.
 * @param sampleRate Frames per second of the signal.
 * @param channelCount Interleaved channels per frame.
 */
class BandEqualizer(config: EqualizerConfig, sampleRate: Int, channelCount: Int) {

    private val channels = channelCount.coerceAtLeast(1)

    private val filters: Array<Biquad> = config.bands
        .filter { it.gainDb != 0.0 }
        .map { Biquad.forBand(it, sampleRate) }
        .toTypedArray()

    /** Two delay elements per channel per filter. */
    private val state = Array(filters.size) { DoubleArray(channels * 2) }

    /** Filters the first [sampleCount] interleaved [samples] in place. */
    fun process(samples: FloatArray, sampleCount: Int = samples.size) {
        if (filters.isEmpty()) return
        val end = sampleCount.coerceAtMost(samples.size)
        var frame = 0
        while (frame + channels <= end) {
            for (c in 0 until channels) {
                var x = samples[frame + c].toDouble()
                for (f in filters.indices) {
                    x = filters[f].step(x, state[f], c * 2)
                }
                samples[frame + c] = x.toFloat()
            }
            frame += channels
        }
    }

    /** Forgets the filters' history, e.g. after a seek. */
    fun reset() {
        for (s in state) s.fill(0.0)
    }
}

/**
 * One second-order section, normalised so `a0` is 1.
 *
 * Internal to the equalizer; exposed to the module only for its tests.
 */
internal class Biquad(
    val b0: Double,
    val b1: Double,
    val b2: Double,
    val a1: Double,
    val a2: Double,
) {

    /** Filters one sample, with [z] holding the delay pair at [offset]. */
    fun step(x: Double, z: DoubleArray, offset: Int): Double {
        val y = b0 * x + z[offset]
        z[offset] = b1 * x - a1 * y + z[offset + 1]
        z[offset + 1] = b2 * x - a2 * y
        return y
    }

    companion object {
        /**
         * The highest frequency a section gets, as a fraction of the sample
         * rate: close to half of it the bilinear transform squeezes the filter
         * flat.
         */
        private const val MAX_CORNER_RATIO = 0.45

        /** The section that passes the signal unchanged. */
        private val IDENTITY = Biquad(1.0, 0.0, 0.0, 0.0, 0.0)

        /** The cookbook's section for [band]. */
        fun forBand(band: EqualizerBand, sampleRate: Int): Biquad = when (band.type) {
            EqualizerBandType.LOW_SHELF -> lowShelf(band.frequencyHz, band.gainDb, sampleRate)
            EqualizerBandType.PEAK -> peak(band.frequencyHz, band.gainDb, band.q, sampleRate)
            EqualizerBandType.HIGH_SHELF -> highShelf(band.frequencyHz, band.gainDb, sampleRate)
        }

        /** The cookbook's low shelf at [frequencyHz], slope 1. */
        fun lowShelf(frequencyHz: Double, gainDb: Double, sampleRate: Int): Biquad =
            shelf(frequencyHz, gainDb, sampleRate, high = false)

        /** The cookbook's high shelf at [frequencyHz], slope 1. */
        fun highShelf(frequencyHz: Double, gainDb: Double, sampleRate: Int): Biquad =
            shelf(frequencyHz, gainDb, sampleRate, high = true)

        /** The cookbook's peak at [frequencyHz], as narrow as [q]. */
        fun peak(frequencyHz: Double, gainDb: Double, q: Double, sampleRate: Int): Biquad {
            if (gainDb == 0.0) return IDENTITY
            val rate = sampleRate.coerceAtLeast(1).toDouble()
            val a = 10.0.pow(gainDb / 40.0)
            val w0 = 2.0 * PI * corner(frequencyHz, rate) / rate
            val alpha = sin(w0) / (2.0 * q)
            val a0 = 1 + alpha / a
            val b1 = -2 * cos(w0) / a0
            return Biquad(
                b0 = (1 + alpha * a) / a0,
                b1 = b1,
                b2 = (1 - alpha * a) / a0,
                a1 = b1,
                a2 = (1 - alpha / a) / a0,
            )
        }

        private fun corner(frequencyHz: Double, rate: Double): Double =
            frequencyHz.coerceIn(1.0, rate * MAX_CORNER_RATIO)

        private fun shelf(
            frequencyHz: Double,
            gainDb: Double,
            sampleRate: Int,
            high: Boolean,
        ): Biquad {
            if (gainDb == 0.0) return IDENTITY
            val rate = sampleRate.coerceAtLeast(1).toDouble()
            val a = 10.0.pow(gainDb / 40.0)
            val w0 = 2.0 * PI * corner(frequencyHz, rate) / rate
            val cosW0 = cos(w0)
            // alpha = sin(w0) / 2 * sqrt((A + 1/A) * (1/S - 1) + 2) with S = 1.
            val alpha = sin(w0) / 2.0 * sqrt(2.0)
            val twoSqrtAAlpha = 2.0 * sqrt(a) * alpha
            val b0: Double
            val b1: Double
            val b2: Double
            val a0: Double
            val a1: Double
            val a2: Double
            if (high) {
                b0 = a * ((a + 1) + (a - 1) * cosW0 + twoSqrtAAlpha)
                b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
                b2 = a * ((a + 1) + (a - 1) * cosW0 - twoSqrtAAlpha)
                a0 = (a + 1) - (a - 1) * cosW0 + twoSqrtAAlpha
                a1 = 2 * ((a - 1) - (a + 1) * cosW0)
                a2 = (a + 1) - (a - 1) * cosW0 - twoSqrtAAlpha
            } else {
                b0 = a * ((a + 1) - (a - 1) * cosW0 + twoSqrtAAlpha)
                b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
                b2 = a * ((a + 1) - (a - 1) * cosW0 - twoSqrtAAlpha)
                a0 = (a + 1) + (a - 1) * cosW0 + twoSqrtAAlpha
                a1 = -2 * ((a - 1) + (a + 1) * cosW0)
                a2 = (a + 1) + (a - 1) * cosW0 - twoSqrtAAlpha
            }
            return Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
        }
    }
}
