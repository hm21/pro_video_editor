package ch.waio.pro_video_editor.src.features.render.helpers

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pins that an amplifying volume limits 16-bit audio near full scale instead
 * of clipping it, and that a volume at or below 1.0 multiplies exactly as it
 * always did.
 */
internal class VolumeAudioProcessorTest {

    @Test
    fun `limits amplified 16-bit audio instead of clipping it`() {
        val output = process(volume = 3f, samples = shortArrayOf(30000, -30000, 30000, -30000))

        val ceiling = (PeakLimiter.CEILING * 32768).toInt()
        assertTrue(output.all { kotlin.math.abs(it.toInt()) <= ceiling + 1 }, "$output")
        assertTrue(output.none { it == Short.MAX_VALUE || it == Short.MIN_VALUE }, "$output")
    }

    @Test
    fun `scales by a volume at or below 1 exactly as before`() {
        val output = process(volume = 0.5f, samples = shortArrayOf(30001, -30001))

        assertEquals(listOf<Short>(15000, -15000), output)
    }

    private fun process(volume: Float, samples: ShortArray): List<Short> {
        val processor = VolumeAudioProcessor(volume)
        processor.configure(AudioFormat(48000, 2, C.ENCODING_PCM_16BIT))
        processor.flush()
        val input = ByteBuffer.allocateDirect(samples.size * 2).order(ByteOrder.nativeOrder())
        samples.forEach { input.putShort(it) }
        input.flip()
        processor.queueInput(input)
        val output = processor.output
        return List(output.remaining() / 2) { output.short }
    }
}
