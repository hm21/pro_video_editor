package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import ch.waio.pro_video_editor.src.features.render.models.VideoClip
import ch.waio.pro_video_editor.src.features.render.helpers.VolumeAudioProcessor
import java.io.File

/**
 * Builder class for creating video sequences with effects in video compositions.
 *
 * Handles multiple video clips, effects, audio normalization, volume control,
 * cropping, and image overlays.
 */
@UnstableApi
class VideoSequenceBuilder(
    private val videoClips: List<VideoClip>
) {
    private var videoEffects: List<Effect> = emptyList()
    private var audioEffects: List<AudioProcessor> = emptyList()
    private var rotationDegrees: Float = 0f
    private var flipX: Boolean = false
    private var flipY: Boolean = false
    private var cropConfig: CropConfig? = null
    private var imageLayerConfig: ImageLayerConfig? = null
    private var enableAudio: Boolean = true
    private var originalAudioVolume: Float? = null
    private var needsAudioNormalization: Boolean = false
    private var forceRemoveAudio: Boolean = false
    private var globalStartUs: Long? = null
    private var globalEndUs: Long? = null
    private var hasCustomAudio: Boolean = false

    data class CropConfig(
        val width: Int?,
        val height: Int?,
        val x: Int?,
        val y: Int?
    )

    data class ImageLayerConfig(
        val imageBytes: ByteArray?,
        val scaleX: Float?,
        val scaleY: Float?,
        val withCropping: Boolean = false
    )

    /**
     * Sets the video effects to apply to all clips.
     */
    fun setVideoEffects(effects: List<Effect>): VideoSequenceBuilder {
        this.videoEffects = effects
        return this
    }

    /**
     * Sets the audio effects to apply to all clips.
     */
    fun setAudioEffects(effects: List<AudioProcessor>): VideoSequenceBuilder {
        this.audioEffects = effects
        return this
    }

    /**
     * Sets rotation in degrees (0, 90, 180, 270).
     */
    fun setRotation(degrees: Float): VideoSequenceBuilder {
        this.rotationDegrees = degrees
        return this
    }

    /**
     * Sets flip configuration.
     */
    fun setFlip(flipX: Boolean, flipY: Boolean): VideoSequenceBuilder {
        this.flipX = flipX
        this.flipY = flipY
        return this
    }

    /**
     * Sets crop configuration.
     */
    fun setCrop(width: Int?, height: Int?, x: Int?, y: Int?): VideoSequenceBuilder {
        this.cropConfig = CropConfig(width, height, x, y)
        return this
    }

    /**
     * Sets image layer overlay configuration.
     */
    fun setImageLayer(
        imageBytes: ByteArray?,
        scaleX: Float?,
        scaleY: Float?,
        withCropping: Boolean = false
    ): VideoSequenceBuilder {
        this.imageLayerConfig = ImageLayerConfig(imageBytes, scaleX, scaleY, withCropping)
        return this
    }

    /**
     * Enables or disables audio in the output.
     */
    fun setEnableAudio(enabled: Boolean): VideoSequenceBuilder {
        this.enableAudio = enabled
        return this
    }

    /**
     * Sets the volume for original video audio.
     */
    fun setOriginalAudioVolume(volume: Float?): VideoSequenceBuilder {
        this.originalAudioVolume = volume
        return this
    }

    /**
     * Enables audio channel normalization (convert all to stereo).
     *
     * Should be enabled when clips have different channel counts.
     */
    fun setAudioNormalization(enabled: Boolean): VideoSequenceBuilder {
        this.needsAudioNormalization = enabled
        return this
    }

    /**
     * Forces removal of audio from all clips.
     *
     * Used when custom audio sample rate is incompatible with video audio.
     */
    fun setForceRemoveAudio(enabled: Boolean): VideoSequenceBuilder {
        this.forceRemoveAudio = enabled
        return this
    }

    /**
     * Sets whether custom audio will be mixed with video audio.
     *
     * When true, volume control is handled by VolumeControlAudioMixer.
     * When false, volume control uses VolumeAudioProcessor on the video sequence.
     */
    fun setHasCustomAudio(hasCustom: Boolean): VideoSequenceBuilder {
        this.hasCustomAudio = hasCustom
        return this
    }

    /**
     * Sets global trim for the entire composition output.
     *
     * This trims the final concatenated result, not individual clips.
     * @param startUs Start time in microseconds (null = from beginning)
     * @param endUs End time in microseconds (null = until end)
     */
    fun setGlobalTrim(startUs: Long?, endUs: Long?): VideoSequenceBuilder {
        this.globalStartUs = startUs
        this.globalEndUs = endUs
        return this
    }

    /**
     * Detects if audio normalization is needed across video clips.
     *
     * @return true if clips have different audio channel counts
     */
    fun detectAudioNormalizationNeeded(): Boolean {
        if (!enableAudio || videoClips.size <= 1) {
            return false
        }

        val audioChannelCounts = videoClips.mapNotNull { clip ->
            MediaInfoExtractor.getAudioChannelCount(clip.inputPath)
        }

        val needsNormalization = audioChannelCounts.isNotEmpty() &&
                audioChannelCounts.toSet().size > 1

        if (needsNormalization) {
            Log.d(
                RENDER_TAG,
                "Audio normalization needed - detected different channel counts: $audioChannelCounts"
            )
        } else if (audioChannelCounts.isNotEmpty()) {
            Log.d(
                RENDER_TAG,
                "Audio normalization NOT needed - all videos have same channel count: ${audioChannelCounts.firstOrNull()}"
            )
        }

        return needsNormalization
    }

    /**
     * Calculates total duration of all video clips combined.
     *
     * @return Total duration in microseconds
     */
    /**
     * Calculates total duration of all video clips combined after global trim.
     *
     * @return Total duration in microseconds
     */
    fun calculateTotalDuration(): Long {
        // Apply global trim first to get accurate duration
        val trimmedClips = applyGlobalTrim(videoClips)
        
        var totalDurationUs = 0L
        trimmedClips.forEach { clip ->
            val clipDurationUs = when {
                clip.endUs != null && clip.startUs != null -> clip.endUs - clip.startUs
                clip.endUs != null -> clip.endUs
                else -> MediaInfoExtractor.getVideoDuration(clip.inputPath)
            }
            totalDurationUs += clipDurationUs
        }
        Log.d(RENDER_TAG, "Total video duration (after global trim): ${totalDurationUs / 1000} ms")
        return totalDurationUs
    }

    /**
     * Builds the video sequence with all configured effects and settings.
     *
     * @return EditedMediaItemSequence for video clips
     */
    fun build(): EditedMediaItemSequence {
        Log.d(RENDER_TAG, "Building video sequence with ${videoClips.size} clips")
        Log.d(RENDER_TAG, "Audio enabled: $enableAudio")
        
        // Apply global trim to clips if set
        val trimmedClips = applyGlobalTrim(videoClips)
        Log.d(RENDER_TAG, "After global trim: ${trimmedClips.size} clips (was ${videoClips.size})")

        // Prepare normalized audio effects with channel mixing if needed
        val normalizedAudioEffects = if (needsAudioNormalization) {
            Log.d(RENDER_TAG, "Adding ChannelMixingAudioProcessor to normalize audio to stereo")
            buildChannelNormalizationEffects()
        } else {
            audioEffects.toList()
        }

        // Build EditedMediaItems for each clip
        val editedMediaItems = trimmedClips.mapIndexed { index, clip ->
            buildEditedMediaItem(index, clip, normalizedAudioEffects)
        }

        Log.d(RENDER_TAG, "Total EditedMediaItems created: ${editedMediaItems.size}")

        // Handle forced audio removal (sample rate mismatch)
        val finalVideoItems = if (forceRemoveAudio) {
            Log.w(
                RENDER_TAG,
                "Force removing original audio from all clips due to sample rate mismatch"
            )
            editedMediaItems.map { item ->
                EditedMediaItem.Builder(item.mediaItem)
                    .setEffects(item.effects)
                    .setRemoveAudio(true)
                    .build()
            }
        } else {
            editedMediaItems
        }

        // Check if first clip has no audio but later clips do
        val firstClipHasAudio = if (enableAudio && videoClips.isNotEmpty()) {
            MediaInfoExtractor.getAudioChannelCount(videoClips[0].inputPath)?.let { it > 0 } ?: false
        } else {
            true // If audio disabled, doesn't matter
        }

        val laterClipHasAudio = if (enableAudio && videoClips.size > 1) {
            videoClips.drop(1).any { clip ->
                MediaInfoExtractor.getAudioChannelCount(clip.inputPath)?.let { it > 0 } ?: false
            }
        } else {
            false
        }

        val needsForceAudioTrack = !firstClipHasAudio && laterClipHasAudio

        if (needsForceAudioTrack) {
            Log.w(
                RENDER_TAG,
                "First clip has no audio but later clips do - using experimentalSetForceAudioTrack"
            )
        }

        return EditedMediaItemSequence.Builder(finalVideoItems)
            .setIsLooping(false)
            .experimentalSetForceAudioTrack(needsForceAudioTrack)
            .build()
    }

    /**
     * Builds channel normalization effects (channel mixer + audio processors).
     *
     * Uses boosted ITU-R BS.775 coefficients for multi-channel downmixing.
     * 
     * The standard ITU-R BS.775 coefficients (1.0, 0.707, 0.707) cause volume loss
     * because the energy distributed across multiple channels doesn't fully translate
     * to stereo. We apply a boost factor of ~1.4 (sqrt(2)) to compensate.
     * 
     * This ensures that surround content maintains similar perceived loudness
     * when mixed with stereo custom audio tracks.
     */
    private fun buildChannelNormalizationEffects(): List<AudioProcessor> {
        val channelMixer = ChannelMixingAudioProcessor()

        // Boost factor to compensate for energy loss during downmixing
        // sqrt(2) ≈ 1.414 compensates for the typical ~70% volume loss
        val boost = 1.4f

        // 7.1 Surround (8 channels) to Stereo (2 channels)
        // Channel order: FL, FR, FC, LFE, BL, BR, SL, SR
        // Boosted coefficients to maintain loudness
        val eightToTwo = floatArrayOf(
            1.0f * boost, 0.0f, 0.707f * boost, 0.0f, 0.707f * boost, 0.0f, 0.707f * boost, 0.0f,  // Left output
            0.0f, 1.0f * boost, 0.707f * boost, 0.0f, 0.0f, 0.707f * boost, 0.0f, 0.707f * boost   // Right output
        )
        channelMixer.putChannelMixingMatrix(
            ChannelMixingMatrix(8, 2, eightToTwo)
        )

        // 5.1 Surround (6 channels) to Stereo (2 channels)
        // Channel order: FL, FR, FC, LFE, BL, BR
        // Boosted ITU-R BS.775: L' = (L + 0.707*C + 0.707*Ls) * boost
        val sixToTwo = floatArrayOf(
            1.0f * boost, 0.0f, 0.707f * boost, 0.0f, 0.707f * boost, 0.0f,  // Left output
            0.0f, 1.0f * boost, 0.707f * boost, 0.0f, 0.0f, 0.707f * boost   // Right output
        )
        channelMixer.putChannelMixingMatrix(
            ChannelMixingMatrix(6, 2, sixToTwo)
        )

        // Quad (4 channels) to Stereo (2 channels)
        // Channel order: FL, FR, BL, BR
        // Slightly lower boost for quad (less energy distributed)
        val boostQuad = 1.2f
        val fourToTwo = floatArrayOf(
            1.0f * boostQuad, 0.0f, 0.707f * boostQuad, 0.0f,  // Left output
            0.0f, 1.0f * boostQuad, 0.0f, 0.707f * boostQuad   // Right output
        )
        channelMixer.putChannelMixingMatrix(
            ChannelMixingMatrix(4, 2, fourToTwo)
        )

        // Stereo (2 channels) to Stereo (2 channels) - passthrough (no boost needed)
        channelMixer.putChannelMixingMatrix(
            ChannelMixingMatrix.create(2, 2)
        )

        // Mono (1 channel) to Stereo (2 channels)
        channelMixer.putChannelMixingMatrix(
            ChannelMixingMatrix.create(1, 2)
        )

        Log.d(RENDER_TAG, "Channel normalization configured with boosted coefficients for loudness preservation")

        return mutableListOf<AudioProcessor>(channelMixer).apply { addAll(audioEffects) }
    }

    /**
     * Builds an EditedMediaItem for a single video clip with all effects.
     */
    private fun buildEditedMediaItem(
        index: Int,
        clip: VideoClip,
        normalizedAudioEffects: List<AudioProcessor>
    ): EditedMediaItem {
        Log.d(RENDER_TAG, "Processing clip $index: ${clip.inputPath}")
        val inputFile = File(clip.inputPath)

        if (!inputFile.exists()) {
            Log.e(RENDER_TAG, "ERROR: Video file does not exist: ${clip.inputPath}")
        } else {
            Log.d(RENDER_TAG, "Video file exists, size: ${inputFile.length()} bytes")
        }

        // Build MediaItem with optional trimming
        val mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(inputFile))

        if (clip.startUs != null || clip.endUs != null) {
            val startMs = (clip.startUs ?: 0L) / 1000
            val endMs = clip.endUs?.div(1000) ?: C.TIME_END_OF_SOURCE
            val expectedDurationMs = if (clip.endUs != null && clip.startUs != null) {
                (clip.endUs - clip.startUs) / 1000
            } else if (clip.endUs != null) {
                clip.endUs / 1000
            } else {
                -1L
            }

            Log.d(
                RENDER_TAG,
                "Applying trim to clip ${clip.inputPath}: start=$startMs ms, end=$endMs ms, expectedDuration=$expectedDurationMs ms"
            )

            val clippingConfig = MediaItem.ClippingConfiguration.Builder()
                .setStartPositionMs(startMs)
                .setEndPositionMs(endMs)
                .build()

            mediaItemBuilder.setClippingConfiguration(clippingConfig)
        }

        val mediaItem = mediaItemBuilder.build()

        // Build video effects
        val clipVideoEffects = mutableListOf<Effect>()
        clipVideoEffects.addAll(videoEffects)

        // Apply image layer BEFORE crop if withCropping is enabled
        // This makes the image get cropped together with the video
        if (imageLayerConfig?.withCropping == true) {
            imageLayerConfig?.let { imageLayer ->
                applyImageLayer(
                    clipVideoEffects,
                    inputFile,
                    imageLayer.imageBytes,
                    rotationDegrees,
                    null, // Don't pass crop dimensions - use original video size
                    null,
                    imageLayer.scaleX,
                    imageLayer.scaleY
                )
            }
        }

        // Apply crop if configured
        cropConfig?.let { crop ->
            applyCrop(
                clipVideoEffects,
                inputFile,
                rotationDegrees,
                flipX,
                flipY,
                crop.width,
                crop.height,
                crop.x,
                crop.y
            )
        }

        // Apply image layer AFTER crop if withCropping is disabled (default behavior)
        // This makes the image stretch to the final cropped size
        if (imageLayerConfig?.withCropping != true) {
            imageLayerConfig?.let { imageLayer ->
                applyImageLayer(
                    clipVideoEffects,
                    inputFile,
                    imageLayer.imageBytes,
                    rotationDegrees,
                    cropConfig?.width,
                    cropConfig?.height,
                    imageLayer.scaleX,
                    imageLayer.scaleY
                )
            }
        }

        // Volume control approach depends on whether we're mixing with custom audio:
        // - With custom audio: VolumeControlAudioMixer handles volume (AudioProcessors don't work with parallel sequences)
        // - Without custom audio: VolumeAudioProcessor works because there's only one sequence
        val volume = originalAudioVolume
        val finalAudioEffects = if (!hasCustomAudio && volume != null && volume != 1.0f) {
            Log.d(
                RENDER_TAG,
                "Video audio volume: ${volume}x (applied via VolumeAudioProcessor - no custom audio)"
            )
            // Add VolumeAudioProcessor for video-only volume control
            val volumeProcessor = VolumeAudioProcessor(volume)
            mutableListOf<AudioProcessor>().apply {
                addAll(normalizedAudioEffects)
                add(volumeProcessor)
            }
        } else {
            if (hasCustomAudio && volume != null && volume != 1.0f) {
                Log.d(
                    RENDER_TAG,
                    "Video audio volume: ${volume}x (applied via VolumeControlAudioMixer - mixing with custom audio)"
                )
            }
            normalizedAudioEffects
        }

        val effects = Effects(finalAudioEffects, clipVideoEffects)

        // Determine if audio should be removed
        val shouldRemoveAudio = !enableAudio ||
                (originalAudioVolume != null && originalAudioVolume == 0.0f)

        if (shouldRemoveAudio) {
            Log.d(
                RENDER_TAG,
                "Removing audio from clip $index (enableAudio=$enableAudio, originalVolume=${originalAudioVolume ?: 1.0f})"
            )
        } else {
            Log.d(RENDER_TAG, "Keeping audio for clip $index (for mixing or normal playback)")
        }

        return EditedMediaItem.Builder(mediaItem)
            .setEffects(effects)
            .setRemoveAudio(shouldRemoveAudio)
            .build()
    }

    /**
     * Applies global trim to clips by adjusting their start/end times.
     *
     * This method calculates which portions of each clip fall within the
     * global trim range and adjusts the clip boundaries accordingly.
     * Clips that fall completely outside the range are excluded.
     *
     * @param clips Original list of video clips
     * @return List of clips with adjusted trim boundaries
     */
    private fun applyGlobalTrim(clips: List<VideoClip>): List<VideoClip> {
        if (globalStartUs == null && globalEndUs == null) {
            return clips
        }

        Log.d(RENDER_TAG, "Applying global trim: start=${globalStartUs?.div(1000)}ms, end=${globalEndUs?.div(1000)}ms")

        val result = mutableListOf<VideoClip>()
        var compositionTimeUs = 0L

        for (clip in clips) {
            // Calculate clip's duration in the composition
            val clipStartInSource = clip.startUs ?: 0L
            val clipEndInSource = clip.endUs ?: MediaInfoExtractor.getVideoDuration(clip.inputPath)
            val clipDurationUs = clipEndInSource - clipStartInSource

            // Calculate clip's position in the composition timeline
            val clipStartInComposition = compositionTimeUs
            val clipEndInComposition = compositionTimeUs + clipDurationUs

            // Check if clip overlaps with global trim range
            val globalStart = globalStartUs ?: 0L
            val globalEnd = globalEndUs ?: Long.MAX_VALUE

            if (clipEndInComposition <= globalStart || clipStartInComposition >= globalEnd) {
                // Clip is completely outside the global trim range - skip it
                Log.d(RENDER_TAG, "Skipping clip (outside global trim range): ${clip.inputPath}")
            } else {
                // Clip overlaps with global trim range - adjust boundaries
                var newStartInSource = clipStartInSource
                var newEndInSource = clipEndInSource

                // Adjust start if global start cuts into this clip
                if (clipStartInComposition < globalStart) {
                    val offsetUs = globalStart - clipStartInComposition
                    newStartInSource = clipStartInSource + offsetUs
                    Log.d(RENDER_TAG, "Adjusting clip start by ${offsetUs / 1000}ms")
                }

                // Adjust end if global end cuts into this clip
                if (clipEndInComposition > globalEnd) {
                    val offsetUs = clipEndInComposition - globalEnd
                    newEndInSource = clipEndInSource - offsetUs
                    
                    // Subtract ~1 frame (33ms for 30fps) to ensure encoder doesn't overshoot
                    // This compensates for encoder rounding to next frame/audio sample boundary
                    val frameCompensationUs = 33333L // ~33ms = 1 frame at 30fps
                    newEndInSource = maxOf(newStartInSource, newEndInSource - frameCompensationUs)
                    
                    Log.d(RENDER_TAG, "Adjusting clip end by ${offsetUs / 1000}ms (with frame compensation)")
                }

                // Only add if there's still content left
                if (newEndInSource > newStartInSource) {
                    result.add(VideoClip(
                        inputPath = clip.inputPath,
                        startUs = newStartInSource,
                        endUs = newEndInSource
                    ))
                    val trimmedDuration = newEndInSource - newStartInSource
                    Log.d(RENDER_TAG, "Added trimmed clip: start=${newStartInSource / 1000}ms, end=${newEndInSource / 1000}ms, duration=${trimmedDuration / 1000}ms")
                }
            }

            compositionTimeUs += clipDurationUs
        }

        // Log total duration after global trim
        val totalTrimmedDuration = result.sumOf { clip ->
            val start = clip.startUs ?: 0L
            val end = clip.endUs ?: 0L
            end - start
        }
        Log.d(RENDER_TAG, "Total duration after global trim: ${totalTrimmedDuration / 1000}ms (target: ${globalEndUs?.minus(globalStartUs ?: 0L)?.div(1000)}ms)")

        return result
    }
}
