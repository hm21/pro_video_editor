package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.EqualizerBand
import ch.waio.pro_video_editor.src.features.render.models.EqualizerBandType
import ch.waio.pro_video_editor.src.features.render.models.EqualizerConfig
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** Pins the order of a clip's own audio processing and its offline run. */
internal class ClipAudioChainTest {

    @Test
    fun `puts the equalizer ahead of the volume`() {
        val equalizer = EqualizerConfig(listOf(EqualizerBand(EqualizerBandType.PEAK, 1000.0, 3.0)))

        val processors = ClipAudioChain.processors(2f, equalizer)

        assertEquals(2, processors.size)
        assertTrue(processors[0] is EqualizerAudioProcessor)
        assertTrue(processors[1] is VolumeAudioProcessor)
    }

    @Test
    fun `leaves out what does not change the audio`() {
        val flat = EqualizerConfig(listOf(EqualizerBand(EqualizerBandType.PEAK, 1000.0, 0.0)))

        assertTrue(ClipAudioChain.processors(1f, EqualizerConfig()).isEmpty())
        assertTrue(ClipAudioChain.processors(1f, flat).isEmpty())
        assertTrue(ClipAudioChain.processors(null, null).isEmpty())
    }

    @Test
    fun `returns the input itself when there is nothing to apply`() {
        val pcm = pcm(1000, -1000)

        assertSame(pcm, ClipAudioChain.apply(pcm, 48000, 2, null, null))
    }

    @Test
    fun `applies the volume to pcm offline`() {
        val output = ClipAudioChain.apply(pcm(30000, -30000), 48000, 2, 0.5f, null)

        val samples = ByteBuffer.wrap(output).order(ByteOrder.nativeOrder())
        assertEquals(15000, samples.short.toInt())
        assertEquals(-15000, samples.short.toInt())
    }

    private fun pcm(vararg samples: Short): ByteArray {
        val buffer = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.nativeOrder())
        samples.forEach { buffer.putShort(it) }
        return buffer.array()
    }
}
