package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.EqualizerBand
import ch.waio.pro_video_editor.src.features.render.models.EqualizerBandType
import ch.waio.pro_video_editor.src.features.render.models.EqualizerConfig
import kotlin.math.PI
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pins the bands' response and their coefficients.
 *
 * The coefficients are compared against literals that the Swift twin and the
 * `divine_video_player` twins pin too: if one platform's formula drifts, the
 * editor preview stops sounding like the export, and this is where it shows.
 */
internal class BandEqualizerTest {

    @Test
    fun `low shelf coefficients match the cookbook values every twin pins`() {
        val biquad = Biquad.lowShelf(200.0, 6.0, 48000)

        assertEquals(1.0064455778511419, biquad.b0, 1e-12)
        assertEquals(-1.9686123523200318, biquad.b1, 1e-12)
        assertEquals(0.9631200582728409, biquad.b2, 1e-12)
        assertEquals(-1.9688501073857254, biquad.a1, 1e-12)
        assertEquals(0.9693278810582894, biquad.a2, 1e-12)
    }

    @Test
    fun `high shelf coefficients match the cookbook values every twin pins`() {
        val biquad = Biquad.highShelf(3000.0, 6.0, 48000)

        assertEquals(1.815113185412132, biquad.b0, 1e-12)
        assertEquals(-2.790024630355969, biquad.b1, 1e-12)
        assertEquals(1.13571665291146, biquad.b2, 1e-12)
        assertEquals(-1.358218880923325, biquad.a1, 1e-12)
        assertEquals(0.519024088890948, biquad.a2, 1e-12)
    }

    @Test
    fun `peak coefficients match the cookbook values every twin pins`() {
        val boost = Biquad.peak(1000.0, 6.0, 0.7071067811865475, 48000)

        assertEquals(1.0610424252634374, boost.b0, 1e-12)
        assertEquals(-1.8612731439964758, boost.b1, 1e-12)
        assertEquals(0.816291571321481, boost.b2, 1e-12)
        assertEquals(-1.8612731439964758, boost.a1, 1e-12)
        assertEquals(0.8773339965849185, boost.a2, 1e-12)

        val cut = Biquad.peak(250.0, -6.0, 0.7071067811865475, 44100)

        assertEquals(0.9828670212502347, cut.b0, 1e-12)
        assertEquals(-1.930079966863433, cut.b1, 1e-12)
        assertEquals(0.9484379496535652, cut.b2, 1e-12)
        assertEquals(-1.930079966863433, cut.a1, 1e-12)
        assertEquals(0.9313049709037998, cut.a2, 1e-12)
    }

    @Test
    fun `a band without gain is the identity section`() {
        for (type in EqualizerBandType.entries) {
            val biquad = Biquad.forBand(EqualizerBand(type, 1000.0, 0.0, 2.0), 48000)

            assertEquals(listOf(1.0, 0.0, 0.0, 0.0, 0.0), biquad.coefficients(), "$type")
        }
    }

    @Test
    fun `builds each band with the section of its type`() {
        val peak = Biquad.forBand(EqualizerBand(EqualizerBandType.PEAK, 1000.0, 6.0, 3.0), 48000)
        val low = Biquad.forBand(EqualizerBand(EqualizerBandType.LOW_SHELF, 200.0, 6.0), 48000)
        val high = Biquad.forBand(EqualizerBand(EqualizerBandType.HIGH_SHELF, 3000.0, 6.0), 48000)

        assertEquals(Biquad.peak(1000.0, 6.0, 3.0, 48000).coefficients(), peak.coefficients())
        assertEquals(Biquad.lowShelf(200.0, 6.0, 48000).coefficients(), low.coefficients())
        assertEquals(Biquad.highShelf(3000.0, 6.0, 48000).coefficients(), high.coefficients())
    }

    @Test
    fun `raising a low shelf lifts low tones and leaves high ones alone`() {
        val equalizer = config(band(EqualizerBandType.LOW_SHELF, 200.0, 6.0))

        assertEquals(6.0, gainDb(equalizer, frequency = 40.0), 0.2)
        assertEquals(3.0, gainDb(equalizer, frequency = 200.0), 0.2)
        assertEquals(0.0, gainDb(equalizer, frequency = 5000.0), 0.2)
    }

    @Test
    fun `cutting a low shelf lowers low tones by the gain`() {
        val equalizer = config(band(EqualizerBandType.LOW_SHELF, 200.0, -12.0))

        assertEquals(-12.0, gainDb(equalizer, frequency = 30.0, sampleRate = 44100), 0.3)
        assertEquals(0.0, gainDb(equalizer, frequency = 5000.0, sampleRate = 44100), 0.2)
    }

    @Test
    fun `raising a high shelf lifts high tones and leaves low ones alone`() {
        val equalizer = config(band(EqualizerBandType.HIGH_SHELF, 3000.0, 6.0))

        assertEquals(6.0, gainDb(equalizer, frequency = 14000.0), 0.4)
        assertEquals(3.0, gainDb(equalizer, frequency = 3000.0), 0.2)
        assertEquals(0.0, gainDb(equalizer, frequency = 60.0), 0.2)
    }

    @Test
    fun `a peak moves a tone at its frequency by its gain and leaves distant ones alone`() {
        val boost = config(band(EqualizerBandType.PEAK, 1000.0, 6.0))

        assertEquals(6.0, gainDb(boost, frequency = 1000.0), 0.1)
        assertEquals(0.0, gainDb(boost, frequency = 125.0), 0.3)
        assertEquals(0.0, gainDb(boost, frequency = 8000.0), 0.3)

        val cut = config(band(EqualizerBandType.PEAK, 250.0, -6.0))

        assertEquals(-6.0, gainDb(cut, frequency = 250.0, sampleRate = 44100), 0.1)
        assertEquals(0.0, gainDb(cut, frequency = 2000.0, sampleRate = 44100), 0.3)
    }

    @Test
    fun `a higher q narrows a peak`() {
        val wide = config(band(EqualizerBandType.PEAK, 1000.0, 6.0))
        val narrow = config(band(EqualizerBandType.PEAK, 1000.0, 6.0, q = 4.0))

        assertEquals(6.0, gainDb(narrow, frequency = 1000.0), 0.1)
        assertTrue(gainDb(wide, frequency = 2000.0) > 2.5)
        assertTrue(gainDb(narrow, frequency = 2000.0) < 0.5)
    }

    @Test
    fun `a cascade moves each tone by the sum of its bands`() {
        val bands = listOf(
            band(EqualizerBandType.LOW_SHELF, 200.0, 6.0),
            band(EqualizerBandType.PEAK, 1000.0, -9.0, q = 2.0),
            band(EqualizerBandType.HIGH_SHELF, 3000.0, 4.0),
            band(EqualizerBandType.PEAK, 60.0, 3.0),
        )
        val cascade = EqualizerConfig(bands)

        for (frequency in listOf(60.0, 400.0, 1000.0, 2500.0, 12000.0)) {
            val sum = bands.sumOf { gainDb(config(it), frequency) }
            assertEquals(sum, gainDb(cascade, frequency), 0.05, "at $frequency Hz")
        }
        // The shelf and the 60 Hz peak add up below; the cut dominates at 1 kHz.
        assertEquals(9.0, gainDb(cascade, frequency = 60.0), 0.5)
        assertEquals(-9.0, gainDb(cascade, frequency = 1000.0), 0.5)
    }

    @Test
    fun `filters each channel on its own`() {
        val sampleRate = 48000
        val frames = sampleRate / 10
        val samples = FloatArray(frames * 2) { i ->
            if (i % 2 == 0) (0.5 * sin(2 * PI * 100.0 * (i / 2) / sampleRate)).toFloat() else 0f
        }

        BandEqualizer(config(band(EqualizerBandType.LOW_SHELF, 200.0, 9.0)), sampleRate, 2)
            .process(samples)

        assertTrue((0 until frames).all { samples[it * 2 + 1] == 0f })
        assertTrue((0 until frames).any { samples[it * 2] != 0f })
    }

    @Test
    fun `reset forgets the history of the last buffer`() {
        val equalizer = BandEqualizer(
            config(band(EqualizerBandType.LOW_SHELF, 200.0, 12.0)),
            48000,
            1,
        )
        equalizer.process(FloatArray(480) { 0.8f })
        equalizer.reset()

        val silence = FloatArray(64)
        equalizer.process(silence)

        assertTrue(silence.all { it == 0f })
    }

    @Test
    fun `a frequency above the highest a section can hold is lowered to it`() {
        val clamped = Biquad.highShelf(30000.0, 6.0, 8000)
        val atLimit = Biquad.highShelf(3600.0, 6.0, 8000)

        assertEquals(atLimit.coefficients(), clamped.coefficients())
        assertEquals(
            Biquad.peak(3600.0, 6.0, 1.0, 8000).coefficients(),
            Biquad.peak(30000.0, 6.0, 1.0, 8000).coefficients(),
        )
    }

    private fun band(
        type: EqualizerBandType,
        frequencyHz: Double,
        gainDb: Double,
        q: Double = EqualizerBand.DEFAULT_Q,
    ) = EqualizerBand(type, frequencyHz, gainDb, q)

    private fun config(band: EqualizerBand) = EqualizerConfig(listOf(band))

    private fun Biquad.coefficients() = listOf(b0, b1, b2, a1, a2)

    /** Gain of [equalizer] on a sine at [frequency], measured after it settles. */
    private fun gainDb(
        equalizer: EqualizerConfig,
        frequency: Double,
        sampleRate: Int = 48000,
    ): Double {
        val frames = sampleRate
        val input = FloatArray(frames) {
            (0.25 * sin(2 * PI * frequency * it / sampleRate)).toFloat()
        }
        val output = input.copyOf()
        BandEqualizer(equalizer, sampleRate, 1).process(output)
        val settled = frames / 2
        return 20 * log10(rms(output, settled) / rms(input, settled))
    }

    private fun rms(samples: FloatArray, from: Int): Double {
        var sum = 0.0
        for (i in from until samples.size) sum += samples[i].toDouble() * samples[i]
        return sqrt(sum / (samples.size - from))
    }
}
