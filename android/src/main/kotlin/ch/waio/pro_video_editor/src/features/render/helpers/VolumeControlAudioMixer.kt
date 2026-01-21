package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.util.Log
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.AudioMixer
import androidx.media3.transformer.DefaultAudioMixer
import java.nio.ByteBuffer

/**
 * Custom AudioMixer.Factory that applies volume control to individual audio sources
 * when mixing multiple audio tracks together.
 *
 * This is necessary because Media3's AudioProcessors on EditedMediaItems are NOT invoked
 * when using parallel sequences (multiple EditedMediaItemSequence in a Composition).
 * The DefaultAudioMixer simply adds all sources together at full volume.
 *
 * This factory creates mixers that automatically apply the configured volumes
 * to each audio source during the mixing process.
 *
 * @property videoAudioVolume Volume multiplier for the video's audio track (0.0-1.0+)
 * @property customAudioVolume Volume multiplier for the custom audio track (0.0-1.0+)
 * @property videoAudioPresent Whether video audio is present (not removed due to volume=0)
 */
@UnstableApi
class VolumeControlAudioMixerFactory(
    private val videoAudioVolume: Float,
    private val customAudioVolume: Float,
    private val videoAudioPresent: Boolean
) : AudioMixer.Factory {

    init {
        Log.d(RENDER_TAG, "VolumeControlAudioMixerFactory created: videoVolume=$videoAudioVolume, customVolume=$customAudioVolume, videoAudioPresent=$videoAudioPresent")
    }

    override fun create(): AudioMixer {
        Log.d(RENDER_TAG, "Creating VolumeControlAudioMixer")
        return VolumeControlAudioMixer(videoAudioVolume, customAudioVolume, videoAudioPresent)
    }
}

/**
 * AudioMixer that wraps DefaultAudioMixer and applies volume control to sources.
 *
 * When sources are added, it tracks their IDs and applies the appropriate volume
 * using DefaultAudioMixer.setSourceVolume() after each source is added.
 *
 * If videoAudioPresent is true (mixing both tracks):
 *   Source 0 = Video audio (first sequence) - applies videoAudioVolume
 *   Source 1 = Custom audio (second sequence) - applies customAudioVolume
 * 
 * If videoAudioPresent is false (replacing audio - video audio removed):
 *   Source 0 = Custom audio (only audio source) - applies customAudioVolume
 */
@UnstableApi
private class VolumeControlAudioMixer(
    private val videoAudioVolume: Float,
    private val customAudioVolume: Float,
    private val videoAudioPresent: Boolean
) : AudioMixer {

    private val delegate: DefaultAudioMixer = DefaultAudioMixer.Factory().create() as DefaultAudioMixer
    private var sourceCount = 0
    private var isConfigured = false
    
    // Track source volumes to ensure they stay applied
    private val sourceVolumes = mutableMapOf<Int, Float>()

    override fun configure(
        outputAudioFormat: AudioProcessor.AudioFormat,
        bufferSizeMs: Int,
        startTimeUs: Long
    ) {
        Log.d(RENDER_TAG, "VolumeControlAudioMixer.configure: format=$outputAudioFormat, bufferSizeMs=$bufferSizeMs, startTimeUs=$startTimeUs")
        delegate.configure(outputAudioFormat, bufferSizeMs, startTimeUs)
        isConfigured = true
        sourceCount = 0
        sourceVolumes.clear()
    }

    override fun supportsSourceAudioFormat(sourceFormat: AudioProcessor.AudioFormat): Boolean {
        return delegate.supportsSourceAudioFormat(sourceFormat)
    }

    override fun addSource(sourceFormat: AudioProcessor.AudioFormat, startTimeUs: Long): Int {
        val sourceId = delegate.addSource(sourceFormat, startTimeUs)
        
        // Determine which volume to apply based on source order and whether video audio is present
        val volume: Float
        val sourceType: String
        
        if (videoAudioPresent) {
            // Both video and custom audio present (mixing mode)
            // Source 0 = Video audio, Source 1+ = Custom audio
            if (sourceCount == 0) {
                volume = videoAudioVolume
                sourceType = "VIDEO AUDIO"
            } else {
                volume = customAudioVolume
                sourceType = "CUSTOM AUDIO"
            }
        } else {
            // Video audio was removed (replace mode) - only custom audio present
            // All sources are custom audio
            volume = customAudioVolume
            sourceType = "CUSTOM AUDIO (replacing video audio)"
        }
        
        Log.d(RENDER_TAG, "VolumeControlAudioMixer: Source $sourceId added ($sourceType), applying volume: $volume")
        
        // Store the volume we want for this source
        sourceVolumes[sourceId] = volume
        
        // Apply volume to this source
        delegate.setSourceVolume(sourceId, volume)
        Log.d(RENDER_TAG, "VolumeControlAudioMixer: setSourceVolume($sourceId, $volume) called")
        
        sourceCount++
        return sourceId
    }

    override fun hasSource(sourceId: Int): Boolean {
        return delegate.hasSource(sourceId)
    }

    override fun setSourceVolume(sourceId: Int, volume: Float) {
        // This is called externally - log it and check if it differs from our intended volume
        val intendedVolume = sourceVolumes[sourceId]
        if (intendedVolume != null && intendedVolume != volume) {
            Log.w(RENDER_TAG, "VolumeControlAudioMixer: External setSourceVolume($sourceId, $volume) differs from intended $intendedVolume - IGNORING external call!")
            // Re-apply our intended volume
            delegate.setSourceVolume(sourceId, intendedVolume)
        } else {
            Log.d(RENDER_TAG, "VolumeControlAudioMixer.setSourceVolume called externally: sourceId=$sourceId, volume=$volume")
            delegate.setSourceVolume(sourceId, volume)
        }
    }

    override fun queueInput(sourceId: Int, sourceBuffer: ByteBuffer) {
        delegate.queueInput(sourceId, sourceBuffer)
    }

    override fun getOutput(): ByteBuffer {
        return delegate.getOutput()
    }

    override fun setEndTimeUs(endTimeUs: Long) {
        delegate.setEndTimeUs(endTimeUs)
    }

    override fun isEnded(): Boolean {
        return delegate.isEnded()
    }

    override fun removeSource(sourceId: Int) {
        Log.d(RENDER_TAG, "VolumeControlAudioMixer: Removing source $sourceId")
        delegate.removeSource(sourceId)
    }

    override fun reset() {
        Log.d(RENDER_TAG, "VolumeControlAudioMixer: Reset")
        delegate.reset()
        sourceCount = 0
        isConfigured = false
        sourceVolumes.clear()
    }
}
