package ch.waio.pro_video_editor.src.features.render.helpers

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import ch.waio.pro_video_editor.src.features.render.models.EqualizerBand
import ch.waio.pro_video_editor.src.features.render.models.EqualizerBandType
import ch.waio.pro_video_editor.src.features.render.models.EqualizerConfig
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pins that the equalizer limits a boost instead of clipping it, leaves a cut
 * unlimited, and stays out of the chain when it has nothing to do.
 */
internal class EqualizerAudioProcessorTest {

    @Test
    fun `stays inactive when the equalizer is flat`() {
        val processor = EqualizerAudioProcessor(EqualizerConfig())

        processor.configure(AudioFormat(48000, 2, C.ENCODING_PCM_16BIT))

        assertFalse(processor.isActive)
    }

    @Test
    fun `stays inactive for an encoding it cannot filter`() {
        val processor = EqualizerAudioProcessor(bass(6.0))

        processor.configure(AudioFormat(48000, 2, C.ENCODING_PCM_24BIT))

        assertFalse(processor.isActive)
    }

    @Test
    fun `limits a bass boost on loud audio instead of clipping it`() {
        val loudBass = ShortArray(9600) { (30000 * sin(2 * PI * 60.0 * it / 48000)).toInt().toShort() }

        val output = process(bass(12.0), loudBass)

        val ceiling = (PeakLimiter.CEILING * 32768).toInt()
        assertTrue(output.all { abs(it.toInt()) <= ceiling + 1 }, "peak ${output.maxOf { abs(it.toInt()) }}")
    }

    @Test
    fun `limits while any band boosts even beside a cut`() {
        val loudBass = ShortArray(9600) { (30000 * sin(2 * PI * 60.0 * it / 48000)).toInt().toShort() }
        val equalizer = EqualizerConfig(
            listOf(
                EqualizerBand(EqualizerBandType.HIGH_SHELF, 3000.0, -12.0),
                EqualizerBand(EqualizerBandType.PEAK, 60.0, 12.0),
            ),
        )

        val output = process(equalizer, loudBass)

        val ceiling = (PeakLimiter.CEILING * 32768).toInt()
        assertTrue(output.all { abs(it.toInt()) <= ceiling + 1 }, "peak ${output.maxOf { abs(it.toInt()) }}")
    }

    @Test
    fun `does not limit a cut`() {
        // A cut can overshoot a little on a square-ish signal; without a
        // limiter that overshoot reaches the output rather than being pulled
        // under the ceiling.
        val square = ShortArray(9600) { (if ((it / 400) % 2 == 0) 30000 else -30000).toShort() }

        val output = process(
            EqualizerConfig(listOf(EqualizerBand(EqualizerBandType.HIGH_SHELF, 3000.0, -12.0))),
            square,
        )

        val ceiling = (PeakLimiter.CEILING * 32768).toInt()
        assertTrue(output.any { abs(it.toInt()) > ceiling }, "peak ${output.maxOf { abs(it.toInt()) }}")
    }

    @Test
    fun `filters float audio as float`() {
        val processor = EqualizerAudioProcessor(bass(6.0))
        processor.configure(AudioFormat(48000, 1, C.ENCODING_PCM_FLOAT))
        processor.flush()
        val input = ByteBuffer.allocateDirect(4800 * 4).order(ByteOrder.nativeOrder())
        repeat(4800) { input.putFloat((0.1 * sin(2 * PI * 40.0 * it / 48000)).toFloat()) }
        input.flip()

        processor.queueInput(input)

        val output = processor.output
        assertEquals(4800 * 4, output.remaining())
        val samples = FloatArray(4800) { output.float }
        assertTrue(samples.maxOf { abs(it) } > 0.15f, "peak ${samples.maxOf { abs(it) }}")
    }

    private fun bass(gainDb: Double) =
        EqualizerConfig(listOf(EqualizerBand(EqualizerBandType.LOW_SHELF, 200.0, gainDb)))

    private fun process(equalizer: EqualizerConfig, samples: ShortArray): List<Short> {
        val processor = EqualizerAudioProcessor(equalizer)
        processor.configure(AudioFormat(48000, 1, C.ENCODING_PCM_16BIT))
        processor.flush()
        val input = ByteBuffer.allocateDirect(samples.size * 2).order(ByteOrder.nativeOrder())
        samples.forEach { input.putShort(it) }
        input.flip()
        processor.queueInput(input)
        val output = processor.output
        return List(output.remaining() / 2) { output.short }
    }
}
