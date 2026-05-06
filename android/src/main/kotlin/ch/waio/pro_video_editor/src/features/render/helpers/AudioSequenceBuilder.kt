package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
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
    private var audioEndTimeUs: Long? = null
    private var compositionStartTimeUs: Long? = null
    private var compositionEndTimeUs: Long? = null

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
     * Sets the end time within the audio source file.
     *
     * @param endTimeUs End time in microseconds within the audio file (null = use full file)
     */
    fun setAudioEndTime(endTimeUs: Long?): AudioSequenceBuilder {
        this.audioEndTimeUs = endTimeUs
        return this
    }

    /**
     * Sets when this audio track should start playing in the composition timeline.
     *
     * @param startTimeUs Composition time in microseconds (null = from beginning)
     */
    fun setCompositionStartTime(startTimeUs: Long?): AudioSequenceBuilder {
        this.compositionStartTimeUs = startTimeUs
        return this
    }

    /**
     * Sets when this audio track should stop playing in the composition timeline.
     *
     * @param endTimeUs Composition time in microseconds (null = until end)
     */
    fun setCompositionEndTime(endTimeUs: Long?): AudioSequenceBuilder {
        this.compositionEndTimeUs = endTimeUs
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

        // Calculate effective audio duration considering source clipping
        val sourceEndUs = audioEndTimeUs?.coerceAtMost(totalAudioDurationUs) ?: totalAudioDurationUs
        val effectiveAudioDurationUs = sourceEndUs - startTimeUs
        if (effectiveAudioDurationUs <= 0) {
            Log.w(
                RENDER_TAG,
                "Start time ($startTimeUs us) exceeds audio end ($sourceEndUs us)"
            )
            return null
        }

        // Calculate target duration based on composition placement
        val compStart = compositionStartTimeUs ?: 0L
        val compEnd = compositionEndTimeUs ?: videoDurationUs
        val targetDurationUs = (compEnd - compStart).coerceAtLeast(0L)

        // Create audio content items with looping or single play.
        // NOTE: AudioProcessor instances cannot be shared across multiple EditedMediaItems.
        // We create fresh effects for each item inside the creation methods.
        val audioContentItems = if (loopAudio) {
            createLoopedAudioItems(
                audioFile,
                sourceEndUs,
                effectiveAudioDurationUs,
                targetDurationUs
            )
        } else {
            createSingleAudioItem(audioFile, sourceEndUs, effectiveAudioDurationUs, targetDurationUs)
        }

        // Build audio sequence using addGap() for leading and trailing silence.
        // This is more efficient than generating temporary silent WAV files
        // and avoids potential NPEs with empty MediaItems.
        val trackTypes = setOf(@C.TrackType C.TRACK_TYPE_AUDIO)
        val sequenceBuilder = EditedMediaItemSequence.Builder(trackTypes)

        // Add leading silence if audio starts after composition time 0.
        if (compStart > 0) {
            sequenceBuilder.addGap(compStart)
            Log.d(RENDER_TAG, "Added ${compStart / 1000}ms leading gap for composition offset")
        }

        for (item in audioContentItems) {
            sequenceBuilder.addItem(item)
        }

        // Add trailing silence so the sequence spans the full video duration.
        val totalContentDurationUs = compStart + targetDurationUs
        if (totalContentDurationUs < videoDurationUs) {
            val trailingDurationUs = videoDurationUs - totalContentDurationUs
            sequenceBuilder.addGap(trailingDurationUs)
            Log.d(RENDER_TAG, "Added ${trailingDurationUs / 1000}ms trailing gap")
        }

        return sequenceBuilder.build()
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
            processors.add(AudioMixingUtils.createStandardStereoMixer())
            Log.d(RENDER_TAG, "Added channel normalization for custom audio")
        }

        // NOTE: Volume control is now handled by VolumeControlAudioMixerFactory
        // because Media3's AudioProcessors on EditedMediaItems are NOT invoked
        // when using parallel sequences (multiple EditedMediaItemSequence).
        // The VolumeAudioProcessor was being configured but never actually processing audio.
        // See VolumeControlAudioMixer which applies volumes during the mixing stage.
        if (volume != 1.0f) {
            Log.d(
                RENDER_TAG,
                "Custom audio volume: ${volume}x (applied via VolumeControlAudioMixer)"
            )
        }

        return processors
    }

    /**
     * Creates audio items with looping to match target duration.
     * First iteration uses startTimeUs offset, subsequent loops start from beginning.
     */
    private fun createLoopedAudioItems(
        audioFile: File,
        sourceEndUs: Long,
        effectiveAudioDurationUs: Long,
        targetDurationUs: Long
    ): List<EditedMediaItem> {
        val audioItems = mutableListOf<EditedMediaItem>()

        if (effectiveAudioDurationUs <= 0 || targetDurationUs <= 0) {
            // Fallback: add audio once without duration constraints
            val audioItem = createAudioItem(audioFile, startTimeUs, null, Effects(buildAudioProcessors(), emptyList()))
            audioItems.add(audioItem)
            return audioItems
        }

        var remainingDurationUs = targetDurationUs
        var loopCount = 0
        var isFirstLoop = true

        while (remainingDurationUs > 0) {
            loopCount++

            // First loop uses startTimeUs offset, subsequent loops start from 0
            val loopStartUs = if (isFirstLoop) startTimeUs else 0L
            val loopEndUs = if (isFirstLoop) sourceEndUs else sourceEndUs
            val loopAudioDurationUs =
                if (isFirstLoop) effectiveAudioDurationUs else (sourceEndUs - 0L)

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
                if (audioEndTimeUs != null) loopEndUs else null
            }

            val audioItem = createAudioItem(audioFile, loopStartUs, endPositionUs, Effects(buildAudioProcessors(), emptyList()))
            audioItems.add(audioItem)
            remainingDurationUs -= loopAudioDurationUs
            isFirstLoop = false
        }

        Log.d(RENDER_TAG, "Custom audio will loop $loopCount times to match target duration")
        return audioItems
    }

    /**
     * Creates a single audio item (no looping). Trims if audio is longer than target duration.
     */
    private fun createSingleAudioItem(
        audioFile: File,
        sourceEndUs: Long,
        effectiveAudioDurationUs: Long,
        targetDurationUs: Long
    ): List<EditedMediaItem> {
        val endPositionUs = if (effectiveAudioDurationUs > targetDurationUs && targetDurationUs > 0) {
            Log.d(RENDER_TAG, "Trimming audio to ${targetDurationUs / 1000} ms (no loop)")
            startTimeUs + targetDurationUs
        } else if (audioEndTimeUs != null) {
            Log.d(
                RENDER_TAG, "Playing audio once (${effectiveAudioDurationUs / 1000} ms, no loop)" +
                        if (startTimeUs > 0) " starting at ${startTimeUs / 1000} ms" else ""
            )
            sourceEndUs
        } else {
            Log.d(
                RENDER_TAG, "Playing audio once (${effectiveAudioDurationUs / 1000} ms, no loop)" +
                        if (startTimeUs > 0) " starting at ${startTimeUs / 1000} ms" else ""
            )
            null
        }
        return listOf(createAudioItem(audioFile, startTimeUs, endPositionUs, Effects(buildAudioProcessors(), emptyList())))
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
