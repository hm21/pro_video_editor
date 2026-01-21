package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.util.Log
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer

/**
 * Custom AudioProcessor to adjust volume of audio stream.
 *
 * Processes 16-bit PCM audio samples by multiplying each sample
 * with the volume multiplier. Ensures no clipping by clamping
 * values to valid Short range (-32768 to 32767).
 *
 * @property volumeMultiplier Volume adjustment factor (0.0=silent, 1.0=unchanged, >1.0=amplified)
 */
@UnstableApi
class VolumeAudioProcessor(private val volumeMultiplier: Float) : BaseAudioProcessor() {

    init {
        Log.d(RENDER_TAG, "VolumeAudioProcessor created with multiplier: $volumeMultiplier")
    }

    override fun onConfigure(inputAudioFormat: androidx.media3.common.audio.AudioProcessor.AudioFormat): androidx.media3.common.audio.AudioProcessor.AudioFormat {
        Log.d(
            RENDER_TAG,
            "VolumeAudioProcessor.onConfigure: sampleRate=${inputAudioFormat.sampleRate}, channels=${inputAudioFormat.channelCount}, encoding=${inputAudioFormat.encoding}"
        )
        // Return the same format - we don't change the audio format, just the amplitude
        return inputAudioFormat
    }

    private var processedFrames = 0
    private var lastLogTime = 0L
    
    override fun queueInput(inputBuffer: ByteBuffer) {
        val remaining = inputBuffer.remaining()
        if (remaining == 0) {
            return
        }
        
        processedFrames++
        val now = System.currentTimeMillis()
        // Log every second to avoid spam
        if (now - lastLogTime > 1000) {
            Log.d(RENDER_TAG, "VolumeAudioProcessor.queueInput: processing frame $processedFrames, bytes=$remaining, volume=$volumeMultiplier")
            lastLogTime = now
        }

        // Get output buffer with same size as input
        val outputBuffer = replaceOutputBuffer(remaining)

        // Process 16-bit PCM samples
        val sampleCount = remaining / 2

        for (i in 0 until sampleCount) {
            // Read 16-bit sample
            val sample = inputBuffer.short

            // Apply volume multiplier
            val adjusted = (sample * volumeMultiplier).toInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())

            // Write adjusted sample
            outputBuffer.putShort(adjusted.toShort())
        }

        // Prepare output buffer for reading
        outputBuffer.flip()

        if (sampleCount <= 10) {
            Log.v(
                RENDER_TAG,
                "VolumeAudioProcessor: processed $sampleCount samples with volume ${volumeMultiplier}x"
            )
        }
    }
}
