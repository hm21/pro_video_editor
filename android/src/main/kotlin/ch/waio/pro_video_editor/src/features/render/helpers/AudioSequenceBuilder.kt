package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.net.Uri
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import java.io.File

/**
 * Builder class for creating custom audio sequences in video compositions.
 *
 * Handles looping, volume control, and channel normalization for custom
 * audio tracks that play alongside or replace original video audio.
 */
@UnstableApi
class AudioSequenceBuilder(
    private val audioPath: String,
    private val videoDurationUs: Long
) {
    private var volume: Float = 1.0f
    private var needsNormalization: Boolean = false
    private var loopAudio: Boolean = true
    private var startTimeUs: Long = 0

    /**
     * Sets the volume multiplier for the custom audio.
     *
     * @param volume Volume factor (0.0=silent, 1.0=unchanged, >1.0=amplified)
     */
    fun setVolume(volume: Float): AudioSequenceBuilder {
        this.volume = volume
        return this
    }

    /**
     * Enables channel normalization (convert to stereo).
     *
     * Should be enabled when video clips have different channel counts
     * to ensure compatibility.
     */
    fun setNormalization(enabled: Boolean): AudioSequenceBuilder {
        this.needsNormalization = enabled
        return this
    }

    /**
     * Sets whether the audio should loop to match video duration.
     *
     * @param loop If true, audio repeats; if false, plays once
     */
    fun setLoop(loop: Boolean): AudioSequenceBuilder {
        this.loopAudio = loop
        return this
    }

    /**
     * Sets the start time offset for the custom audio.
     *
     * @param startTimeUs Start time in microseconds from the beginning of the audio file
     */
    fun setStartTime(startTimeUs: Long?): AudioSequenceBuilder {
        this.startTimeUs = startTimeUs ?: 0
        return this
    }

    /**
     * Builds the audio sequence with looping to match video duration.
     *
     * @return EditedMediaItemSequence for custom audio, or null if file not found
     */
    fun build(): EditedMediaItemSequence? {
        Log.d(RENDER_TAG, "Building custom audio sequence: $audioPath")
        Log.d(RENDER_TAG, "Custom audio volume: $volume")
        if (startTimeUs > 0) {
            Log.d(RENDER_TAG, "Custom audio start offset: ${startTimeUs / 1000} ms")
        }

        val audioFile = File(audioPath)
        if (!audioFile.exists()) {
            Log.e(RENDER_TAG, "Custom audio file not found: $audioPath")
            return null
        }

        val totalAudioDurationUs = MediaInfoExtractor.getAudioDuration(audioPath)
        if (totalAudioDurationUs == 0L) {
            Log.w(RENDER_TAG, "Cannot determine custom audio duration")
            return null
        }

        // Calculate effective audio duration after start offset
        val effectiveAudioDurationUs = totalAudioDurationUs - startTimeUs
        if (effectiveAudioDurationUs <= 0) {
            Log.w(RENDER_TAG, "Start time ($startTimeUs us) exceeds audio duration ($totalAudioDurationUs us)")
            return null
        }

        // Build audio effects
        val audioProcessors = buildAudioProcessors()
        val audioEffects = Effects(audioProcessors, emptyList())

        // Create audio items with looping or single play
        val audioItems = if (loopAudio) {
            createLoopedAudioItems(audioFile, totalAudioDurationUs, effectiveAudioDurationUs, audioEffects)
        } else {
            createSingleAudioItem(audioFile, effectiveAudioDurationUs, audioEffects)
        }

        return EditedMediaItemSequence.Builder(audioItems).build()
    }

    /**
     * Builds audio processors for custom audio (channel mixing + volume).
     *
     * Uses ITU-R BS.775 standard coefficients for multi-channel downmixing.
     */
    private fun buildAudioProcessors(): List<AudioProcessor> {
        val processors = mutableListOf<AudioProcessor>()

        // Add channel mixing if needed
        if (needsNormalization) {
            val channelMixer = ChannelMixingAudioProcessor()

            // 7.1 Surround (8 channels) to Stereo (2 channels)
            // Channel order: FL, FR, FC, LFE, BL, BR, SL, SR
            val eightToTwo = floatArrayOf(
                1.0f, 0.0f, 0.707f, 0.0f, 0.707f, 0.0f, 0.707f, 0.0f,  // Left output
                0.0f, 1.0f, 0.707f, 0.0f, 0.0f, 0.707f, 0.0f, 0.707f   // Right output
            )
            channelMixer.putChannelMixingMatrix(
                ChannelMixingMatrix(8, 2, eightToTwo)
            )

            // 5.1 Surround (6 channels) to Stereo (2 channels)
            // ITU-R BS.775 standard
            val sixToTwo = floatArrayOf(
                1.0f, 0.0f, 0.707f, 0.0f, 0.707f, 0.0f,  // Left output
                0.0f, 1.0f, 0.707f, 0.0f, 0.0f, 0.707f   // Right output
            )
            channelMixer.putChannelMixingMatrix(
                ChannelMixingMatrix(6, 2, sixToTwo)
            )

            // Quad (4 channels) to Stereo (2 channels)
            val fourToTwo = floatArrayOf(
                1.0f, 0.0f, 0.707f, 0.0f,  // Left output
                0.0f, 1.0f, 0.0f, 0.707f   // Right output
            )
            channelMixer.putChannelMixingMatrix(
                ChannelMixingMatrix(4, 2, fourToTwo)
            )

            // Stereo (2 channels) to Stereo (2 channels) - passthrough
            channelMixer.putChannelMixingMatrix(
                ChannelMixingMatrix.create(2, 2)
            )

            // Mono (1 channel) to Stereo (2 channels)
            channelMixer.putChannelMixingMatrix(
                ChannelMixingMatrix.create(1, 2)
            )

            processors.add(channelMixer)
            Log.d(RENDER_TAG, "Added channel normalization for custom audio")
        }

        // NOTE: Volume control is now handled by VolumeControlAudioMixerFactory
        // because Media3's AudioProcessors on EditedMediaItems are NOT invoked
        // when using parallel sequences (multiple EditedMediaItemSequence).
        // The VolumeAudioProcessor was being configured but never actually processing audio.
        // See VolumeControlAudioMixer which applies volumes during the mixing stage.
        if (volume != 1.0f) {
            Log.d(RENDER_TAG, "Custom audio volume: ${volume}x (applied via VolumeControlAudioMixer)")
        }

        return processors
    }

    /**
     * Creates audio items with looping to match video duration.
     * First iteration uses startTimeUs offset, subsequent loops start from beginning.
     */
    private fun createLoopedAudioItems(
        audioFile: File,
        totalAudioDurationUs: Long,
        effectiveAudioDurationUs: Long,
        effects: Effects
    ): List<EditedMediaItem> {
        val audioItems = mutableListOf<EditedMediaItem>()

        if (effectiveAudioDurationUs <= 0 || videoDurationUs <= 0) {
            // Fallback: add audio once without duration constraints
            val audioItem = createAudioItem(audioFile, startTimeUs, null, effects)
            audioItems.add(audioItem)
            return audioItems
        }

        var remainingDurationUs = videoDurationUs
        var loopCount = 0
        var isFirstLoop = true

        while (remainingDurationUs > 0) {
            loopCount++
            
            // First loop uses startTimeUs offset, subsequent loops start from 0
            val loopStartUs = if (isFirstLoop) startTimeUs else 0L
            val loopAudioDurationUs = if (isFirstLoop) effectiveAudioDurationUs else totalAudioDurationUs
            
            val endPositionUs = if (remainingDurationUs < loopAudioDurationUs) {
                Log.d(
                    RENDER_TAG,
                    "Loop $loopCount: Trimming audio to ${remainingDurationUs / 1000} ms (final loop)"
                )
                loopStartUs + remainingDurationUs
            } else {
                Log.d(
                    RENDER_TAG,
                    "Loop $loopCount: Using audio duration ${loopAudioDurationUs / 1000} ms" +
                    if (isFirstLoop && startTimeUs > 0) " (starting at ${startTimeUs / 1000} ms)" else ""
                )
                null // Use full remaining audio
            }

            val audioItem = createAudioItem(audioFile, loopStartUs, endPositionUs, effects)
            audioItems.add(audioItem)
            remainingDurationUs -= loopAudioDurationUs
            isFirstLoop = false
        }

        Log.d(RENDER_TAG, "Custom audio will loop $loopCount times to match video duration")
        return audioItems
    }

    /**
     * Creates a single audio item (no looping). Trims if audio is longer than video.
     */
    private fun createSingleAudioItem(
        audioFile: File,
        effectiveAudioDurationUs: Long,
        effects: Effects
    ): List<EditedMediaItem> {
        val endPositionUs = if (effectiveAudioDurationUs > videoDurationUs && videoDurationUs > 0) {
            Log.d(RENDER_TAG, "Trimming audio to ${videoDurationUs / 1000} ms (no loop)")
            startTimeUs + videoDurationUs
        } else {
            Log.d(RENDER_TAG, "Playing audio once (${effectiveAudioDurationUs / 1000} ms, no loop)" +
                if (startTimeUs > 0) " starting at ${startTimeUs / 1000} ms" else "")
            null
        }
        return listOf(createAudioItem(audioFile, startTimeUs, endPositionUs, effects))
    }

    /**
     * Creates a single audio EditedMediaItem with start offset and optional end position.
     */
    private fun createAudioItem(
        audioFile: File,
        startPositionUs: Long,
        endPositionUs: Long?,
        effects: Effects
    ): EditedMediaItem {
        val mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(audioFile))

        if (startPositionUs > 0 || endPositionUs != null) {
            val clippingConfig = MediaItem.ClippingConfiguration.Builder()
                .setStartPositionMs(startPositionUs / 1000)
            
            if (endPositionUs != null) {
                clippingConfig.setEndPositionMs(endPositionUs / 1000)
            }
            
            mediaItemBuilder.setClippingConfiguration(clippingConfig.build())
        }

        val mediaItem = mediaItemBuilder.build()
        return EditedMediaItem.Builder(mediaItem)
            .setRemoveVideo(true)
            .setEffects(effects)
            .build()
    }
}
