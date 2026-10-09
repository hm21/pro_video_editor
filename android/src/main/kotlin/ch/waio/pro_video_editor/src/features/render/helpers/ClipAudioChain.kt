package ch.waio.pro_video_editor.src.features.render.helpers

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.features.render.models.EqualizerConfig
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * A clip's own audio processing — its equalizer, then its volume — as one
 * list, so every place that plays a clip's audio processes it the same way.
 */
@UnstableApi
internal object ClipAudioChain {

    /** The processors for a clip at [volume] with [equalizer], in order. */
    fun processors(volume: Float?, equalizer: EqualizerConfig?): List<AudioProcessor> =
        buildList {
            equalizer?.takeUnless { it.isFlat }?.let { add(EqualizerAudioProcessor(it)) }
            if (volume != null && volume != 1.0f) add(VolumeAudioProcessor(volume))
        }

    /**
     * Runs interleaved 16-bit [pcm] through the clip chain for [volume] and
     * [equalizer] and returns the result, the same length; [pcm] itself when
     * there is nothing to apply.
     *
     * For audio that never passes through a Transformer item of the clip's
     * own, such as the two sides of a pre-rendered overlap transition.
     */
    fun apply(
        pcm: ByteArray,
        sampleRate: Int,
        channelCount: Int,
        volume: Float?,
        equalizer: EqualizerConfig?,
    ): ByteArray {
        val processors = processors(volume, equalizer)
        if (processors.isEmpty() || pcm.isEmpty()) return pcm
        var data = pcm
        val format = AudioProcessor.AudioFormat(sampleRate, channelCount, C.ENCODING_PCM_16BIT)
        for (processor in processors) {
            processor.configure(format)
            if (!processor.isActive) continue
            processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
            val input = ByteBuffer.allocateDirect(data.size).order(ByteOrder.nativeOrder())
            input.put(data).flip()
            processor.queueInput(input)
            val output = processor.output
            data = ByteArray(output.remaining()).also { output.get(it) }
            processor.reset()
        }
        return data
    }
}
