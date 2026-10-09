package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.features.render.models.EqualizerConfig
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/**
 * Applies an [EqualizerConfig] to one source's 16-bit or float PCM, before its
 * volume.
 *
 * A boost can push material that is already near full scale past it, so while
 * any band raises the audio a [PeakLimiter] keeps the filtered signal at
 * -1 dBFS instead of clipping it, the same ceiling an amplifying
 * [VolumeAudioProcessor] limits at. Cuts alone are not limited. A flat
 * equalizer, or an encoding other than 16-bit or float PCM, leaves the
 * processor inactive and the audio untouched.
 *
 * Each source needs an instance of its own: the filters carry state from one
 * buffer to the next.
 */
@UnstableApi
class EqualizerAudioProcessor(private val equalizer: EqualizerConfig) : BaseAudioProcessor() {

    private var filters: BandEqualizer? = null
    private var limiter: PeakLimiter? = null

    /** The samples a buffer is filtered in, kept so a buffer allocates nothing. */
    private var samples = FloatArray(0)

    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        if (equalizer.isFlat) return AudioFormat.NOT_SET
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT &&
            inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT
        ) {
            Log.w(
                RENDER_TAG,
                "EqualizerAudioProcessor: encoding ${inputAudioFormat.encoding} not " +
                    "supported, equalizer $equalizer is not applied"
            )
            return AudioFormat.NOT_SET
        }
        filters = BandEqualizer(
            equalizer,
            inputAudioFormat.sampleRate,
            inputAudioFormat.channelCount,
        )
        limiter = if (equalizer.boosts) PeakLimiter(inputAudioFormat.sampleRate) else null
        return inputAudioFormat
    }

    override fun onFlush(streamMetadata: AudioProcessor.StreamMetadata) {
        filters?.reset()
        limiter?.reset()
    }

    override fun onReset() {
        filters = null
        limiter = null
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val remaining = inputBuffer.remaining()
        if (remaining == 0) return
        val filters = filters ?: return
        val isFloat = inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT
        val count = remaining / if (isFloat) 4 else 2
        if (samples.size < count) samples = FloatArray(count)
        val samples = samples
        for (i in 0 until count) {
            samples[i] = if (isFloat) inputBuffer.float else inputBuffer.short / SHORT_SCALE
        }
        filters.process(samples, count)
        limiter?.process(samples, inputAudioFormat.channelCount, 1f, count)
        val outputBuffer = replaceOutputBuffer(remaining)
        for (i in 0 until count) {
            if (isFloat) {
                outputBuffer.putFloat(samples[i])
            } else {
                outputBuffer.putShort(
                    (samples[i] * SHORT_SCALE).roundToInt()
                        .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                        .toShort(),
                )
            }
        }
        outputBuffer.flip()
    }

    private companion object {
        /** Full scale of 16-bit PCM as a float sample of 1.0. */
        const val SHORT_SCALE = 32768f
    }
}
