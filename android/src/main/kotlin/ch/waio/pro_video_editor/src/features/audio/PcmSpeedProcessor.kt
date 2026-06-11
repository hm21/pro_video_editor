package ch.waio.pro_video_editor.src.features.audio

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Applies a pitch-preserving playback speed change to a stream of 16-bit PCM
 * audio using Media3's [SonicAudioProcessor].
 *
 * The processor is fed interleaved little-endian 16-bit PCM via [process] and
 * returns the time-stretched output. [drain] must be called once at the end of
 * the stream to flush any samples buffered internally by Sonic.
 *
 * This mirrors the speed handling used in the video render pipeline
 * (see `applyPlaybackSpeed`), keeping audio extraction consistent: a value of
 * `2.0` plays twice as fast while keeping the original pitch.
 */
@UnstableApi
class PcmSpeedProcessor(
    speed: Float,
    sampleRate: Int,
    channelCount: Int
) {
    private val sonic = SonicAudioProcessor().apply {
        setSpeed(speed)
        // Pitch is intentionally left at 1.0 so only the duration changes.
        configure(
            AudioProcessor.AudioFormat(sampleRate, channelCount, C.ENCODING_PCM_16BIT)
        )
        // SonicAudioProcessor only overrides flush(StreamMetadata); the no-arg
        // flush() default throws, so call the StreamMetadata overload directly.
        flush(AudioProcessor.StreamMetadata.DEFAULT)
    }

    /**
     * Feeds a chunk of 16-bit PCM and returns whatever output is currently
     * available (may be empty while Sonic buffers internally).
     */
    fun process(pcm: ByteArray): ByteArray {
        sonic.queueInput(ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN))
        return collectOutput()
    }

    /**
     * Signals end-of-stream and returns any remaining buffered output.
     */
    fun drain(): ByteArray {
        sonic.queueEndOfStream()
        val output = ByteArrayOutputStream()
        output.write(collectOutput())
        while (!sonic.isEnded) {
            val chunk = collectOutput()
            if (chunk.isEmpty()) break
            output.write(chunk)
        }
        sonic.reset()
        return output.toByteArray()
    }

    private fun collectOutput(): ByteArray {
        val output = ByteArrayOutputStream()
        var buffer = sonic.output
        while (buffer.hasRemaining()) {
            val chunk = ByteArray(buffer.remaining())
            buffer.get(chunk)
            output.write(chunk)
            buffer = sonic.output
        }
        return output.toByteArray()
    }
}
