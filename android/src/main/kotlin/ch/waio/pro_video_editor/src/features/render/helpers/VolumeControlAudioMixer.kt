package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.AudioMixer
import androidx.media3.transformer.DefaultAudioMixer
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
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
 * @property trackVolumes Volume multipliers for each audio track sequence (0.0-1.0+)
 * @property videoAudioSourceCount Number of video sequences that have active audio
 * @property videoSequenceVolumes Volume multipliers for each video sequence
 */
@UnstableApi
class VolumeControlAudioMixerFactory(
    private val trackVolumes: List<Float>,
    private val videoAudioSourceCount: Int,
    private val videoSequenceVolumes: List<Float>
) : AudioMixer.Factory {

    init {
        Log.d(
            RENDER_TAG,
            "VolumeControlAudioMixerFactory created: trackVolumes=$trackVolumes, " +
                    "videoAudioSourceCount=$videoAudioSourceCount, videoSequenceVolumes=$videoSequenceVolumes"
        )
    }

    override fun create(): AudioMixer {
        Log.d(RENDER_TAG, "Creating VolumeControlAudioMixer")
        return VolumeControlAudioMixer(trackVolumes, videoAudioSourceCount, videoSequenceVolumes)
    }
}

/**
 * AudioMixer that wraps DefaultAudioMixer and applies volume control to sources.
 *
 * When sources are added, it tracks their IDs and applies the appropriate volume
 * using DefaultAudioMixer.setSourceVolume() after each source is added.
 *
 * Source order in Media3 Composition (Mixed):
 *   Source 0..N-1 = Video audio (from each sequence that has an AUDIO track)
 *   Source N..M = Audio tracks
 */
@UnstableApi
private class VolumeControlAudioMixer(
    private val trackVolumes: List<Float>,
    private val videoAudioSourceCount: Int,
    private val videoSequenceVolumes: List<Float>
) : AudioMixer {

    private val delegate: DefaultAudioMixer =
        DefaultAudioMixer.Factory().create() as DefaultAudioMixer
    private var sourceCount = 0
    private var isConfigured = false

    // Track source volumes to ensure they stay applied
    private val sourceVolumes = mutableMapOf<Int, Float>()

    override fun configure(
        outputAudioFormat: AudioProcessor.AudioFormat,
        bufferSizeMs: Int,
        startTimeUs: Long
    ) {
        Log.d(
            RENDER_TAG,
            "VolumeControlAudioMixer.configure: format=$outputAudioFormat, bufferSizeMs=$bufferSizeMs, startTimeUs=$startTimeUs"
        )
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

        // Determine which volume to apply based on source order
        val volume: Float
        val sourceType: String

        if (sourceCount < videoAudioSourceCount) {
            // Source is a video audio track
            volume = videoSequenceVolumes.getOrElse(sourceCount) { 1.0f }
            sourceType = "VIDEO AUDIO (Sequence $sourceCount)"
        } else {
            // Source is an audio track
            val trackIndex = sourceCount - videoAudioSourceCount
            volume = trackVolumes.getOrElse(trackIndex) { 1.0f }
            sourceType = "AUDIO TRACK $trackIndex"
        }

        Log.d(
            RENDER_TAG,
            "VolumeControlAudioMixer: Source $sourceId added ($sourceType), applying volume: $volume"
        )

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
            Log.w(
                RENDER_TAG,
                "VolumeControlAudioMixer: External setSourceVolume($sourceId, $volume) differs from intended $intendedVolume - IGNORING external call!"
            )
            // Re-apply our intended volume
            delegate.setSourceVolume(sourceId, intendedVolume)
        } else {
            Log.d(
                RENDER_TAG,
                "VolumeControlAudioMixer.setSourceVolume called externally: sourceId=$sourceId, volume=$volume"
            )
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
