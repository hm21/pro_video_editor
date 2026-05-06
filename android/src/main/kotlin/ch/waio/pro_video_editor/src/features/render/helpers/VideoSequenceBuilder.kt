package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.net.Uri
import applyScale
import applyRotation
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
import ch.waio.pro_video_editor.src.features.render.models.LayerAnimationConfig
import ch.waio.pro_video_editor.src.features.render.models.VideoClip
import ch.waio.pro_video_editor.src.features.render.utils.getRotatedVideoDimensions
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
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
    private var enableAudio: Boolean = true
    private var needsAudioNormalization: Boolean = false
    private var forceRemoveAudio: Boolean = false
    private var globalStartUs: Long? = null
    private var globalEndUs: Long? = null
    private var hasCustomAudio: Boolean = false
    private var scaleX: Float? = null
    private var scaleY: Float? = null
    private var renderWidth: Int? = null
    private var renderHeight: Int? = null

    data class CropConfig(
        val width: Int?,
        val height: Int?,
        val x: Int?,
        val y: Int?
    )

    /**
     * Sets target render dimensions for composition-based positioning.
     */
    fun setRenderDimensions(width: Int?, height: Int?): VideoSequenceBuilder {
        this.renderWidth = width
        this.renderHeight = height
        return this
    }

    /**
     * Sets the video effects to apply to all clips.
     */
    fun setVideoEffects(effects: List<Effect>): VideoSequenceBuilder {
        this.videoEffects = effects
        return this
    }

    /**
     * Sets the scale factors to apply after overlay and crop.
     */
    fun setScale(scaleX: Float?, scaleY: Float?): VideoSequenceBuilder {
        this.scaleX = scaleX
        this.scaleY = scaleY
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
     * Enables or disables audio in the output.
     */
    fun setEnableAudio(enabled: Boolean): VideoSequenceBuilder {
        this.enableAudio = enabled
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
     * Only considers clips that have audio enabled (not muted).
     *
     * @return true if any active clip has > 2 channels (needs downmixing)
     */
    /**
     * Detects if audio normalization is needed across video clips.
     *
     * @return true if any clip has non-stereo audio (needs downmixing)
     */
    fun detectAudioNormalizationNeeded(): Boolean {
        if (!enableAudio) {
            return false
        }

        val audioChannelCounts = videoClips.mapNotNull { clip ->
            MediaInfoExtractor.getAudioChannelCount(clip.inputPath)
        }

        // Normalize if any clip is NOT Stereo (2 channels).
        // This includes Mono (1 channel) and Multi-channel (5.1/7.1).
        // Forcing Stereo consistency prevents reconfiguration errors in Media3 AudioGraph.
        val needsNormalization = audioChannelCounts.any { it != 2 }

        if (needsNormalization) {
            Log.d(
                RENDER_TAG,
                "Audio normalization needed - non-stereo audio detected: $audioChannelCounts"
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
                clip.startUs != null -> MediaInfoExtractor.getVideoDuration(clip.inputPath) - clip.startUs
                else -> MediaInfoExtractor.getVideoDuration(clip.inputPath) - (clip.startUs ?: 0L)
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

        // Build EditedMediaItems for each clip
        val editedMediaItems = trimmedClips.mapIndexed { index, clip ->
            // Audio normalization is now handled primarily via pre-transcoding.
            // We keep the processor for edge cases where pre-transcoding was skipped.
            val itemAudioProcessors = mutableListOf<AudioProcessor>()
            if (needsAudioNormalization) {
                itemAudioProcessors.add(AudioMixingUtils.createStandardStereoMixer())
            }
            itemAudioProcessors.addAll(audioEffects)

            buildEditedMediaItem(index, clip, itemAudioProcessors)
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

        // Determine track types for the sequence
        val trackTypes = mutableSetOf<@C.TrackType Int>(C.TRACK_TYPE_VIDEO)
        
        // ONLY add audio track type if at least one item provides audio
        if (enableAudio && finalVideoItems.any { !it.removeAudio }) {
            trackTypes.add(C.TRACK_TYPE_AUDIO)
            Log.d(RENDER_TAG, "Sequence will include AUDIO track")
        } else {
            Log.d(RENDER_TAG, "Sequence will NOT include AUDIO track (muted or disabled)")
        }

        return EditedMediaItemSequence.Builder(trackTypes)
            .addItems(finalVideoItems)
            .setIsLooping(false)
            .build()
    }

    /**
     * Builds an EditedMediaItem for a single video clip with all effects.
     */
    private fun isImageFile(path: String): Boolean {
        val extension = path.substringAfterLast('.', "").lowercase()
        return extension in listOf("jpg", "jpeg", "png", "webp", "heic", "heif")
    }

    private fun buildEditedMediaItem(
        index: Int,
        clip: VideoClip,
        normalizedAudioEffects: List<AudioProcessor>
    ): EditedMediaItem {
        Log.d(RENDER_TAG, "Processing clip $index: ${clip.inputPath}")
        val inputFile = File(clip.inputPath)

        if (!inputFile.exists()) {
            Log.e(RENDER_TAG, "ERROR: Video file does not exist: ${clip.inputPath}")
        }

        // Build MediaItem with optional trimming
        val mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(inputFile))

        val isImage = isImageFile(clip.inputPath)
        if (isImage) {
            val durationUs = when {
                clip.endUs != null -> clip.endUs - (clip.startUs ?: 0L)
                else -> MediaInfoExtractor.getVideoDuration(clip.inputPath) - (clip.startUs ?: 0L)
            }
            mediaItemBuilder.setImageDurationMs(maxOf(1, durationUs / 1000))

            // Map common extensions to MIME types for Transformer
            val extension = clip.inputPath.substringAfterLast('.', "").lowercase()
            val mimeType = when (extension) {
                "png" -> "image/png"
                "webp" -> "image/webp"
                "heic", "heif" -> "image/heif"
                else -> "image/jpeg"
            }
            mediaItemBuilder.setMimeType(mimeType)
        }

        if (clip.startUs != null || clip.endUs != null) {
            val startMs = (clip.startUs ?: 0L) / 1000
            
            // Explicitly use C.TIME_END_OF_SOURCE only if endUs is null.
            // If it's provided, ensure it's not accidentally set to Long.MIN_VALUE via overflow/underflow.
            val endMs = if (clip.endUs != null) {
                clip.endUs / 1000
            } else {
                C.TIME_END_OF_SOURCE
            }

            Log.d(
                RENDER_TAG,
                "Applying trim to clip ${clip.inputPath}: start=$startMs ms, end=$endMs ms"
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

        // Calculate video dimensions for image layer positioning
        // This must be done before applying any effects
        var (videoWidth, videoHeight, videoRotation) = getRotatedVideoDimensions(
            inputFile,
            rotationDegrees
        )

        // Apply rotation early so subsequent effects (Crop, Composition) see correctly oriented frames
        applyRotation(clipVideoEffects, videoRotation.toFloat())

        // Adjust dimensions based on rotation
        val isRotated90Deg = videoRotation == 90 || videoRotation == 270

        // If crop is applied, update dimensions for AFTER crop scenario
        val crop = cropConfig
        if (crop != null) {
            // Apply crop if configured
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

            // Update dimensions after crop for image layers applied AFTER crop
            val croppedWidth: Int? = if (isRotated90Deg) crop.height else crop.width
            val croppedHeight: Int? = if (isRotated90Deg) crop.width else crop.height
            if (croppedWidth != null) videoWidth = croppedWidth
            if (croppedHeight != null) videoHeight = croppedHeight
        }

        // Apply composition transformation if render dimensions are set.
        // This ensures consistent canvas sizing.
        if (renderWidth != null && renderHeight != null) {
            clipVideoEffects += VideoCompositionTransformation(
                x = clip.x,
                y = clip.y,
                width = clip.width,
                height = clip.height,
                videoWidth = videoWidth,
                videoHeight = videoHeight,
                renderWidth = renderWidth!!,
                renderHeight = renderHeight!!
            )
        }

        // Apply scale AFTER overlay and crop to match the iOS/macOS pipeline.
        // This prevents the overlay from being distorted by a pre-applied scale.
        applyScale(clipVideoEffects, scaleX, scaleY)

        // Apply opacity
        applyOpacity(clipVideoEffects, clip.opacity)

        // Per-clip volume control:
        // - Without custom audio: VolumeAudioProcessor per clip works (single sequence)
        // - With custom audio: AudioProcessors don't work with parallel sequences,
        //   so per-clip volume is best-effort (applied via VolumeControlAudioMixer globally)
        val clipVolume = clip.volume
        val finalAudioEffects = if (!hasCustomAudio && clipVolume != null && clipVolume != 1.0f) {
            Log.d(
                RENDER_TAG,
                "Clip $index volume: ${clipVolume}x (applied via VolumeAudioProcessor)"
            )
            val volumeProcessor = VolumeAudioProcessor(clipVolume)
            mutableListOf<AudioProcessor>().apply {
                addAll(normalizedAudioEffects)
                add(volumeProcessor)
            }
        } else {
            normalizedAudioEffects
        }

        val effects = Effects(finalAudioEffects, clipVideoEffects)

        // Determine if audio should be removed
        val shouldRemoveAudio = !enableAudio ||
                (clipVolume != null && clipVolume == 0.0f)

        if (shouldRemoveAudio) {
            Log.d(
                RENDER_TAG,
                "Removing audio from clip $index (enableAudio=$enableAudio, clipVolume=${clipVolume ?: 1.0f})"
            )
        } else {
            Log.d(RENDER_TAG, "Keeping audio for clip $index (for mixing or normal playback)")
        }

        return EditedMediaItem.Builder(mediaItem)
            .setEffects(effects)
            .setRemoveAudio(shouldRemoveAudio)
            .apply {
                if (isImage) {
                    setFrameRate(30)
                }
            }
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

        Log.d(
            RENDER_TAG,
            "Applying global trim: start=${globalStartUs?.div(1000)}ms, end=${globalEndUs?.div(1000)}ms"
        )

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

                    Log.d(
                        RENDER_TAG,
                        "Adjusting clip end by ${offsetUs / 1000}ms (with frame compensation)"
                    )
                }

                // Only add if there's still content left
                if (newEndInSource > newStartInSource) {
                    result.add(
                        VideoClip(
                            inputPath = clip.inputPath,
                            startUs = newStartInSource,
                            endUs = newEndInSource,
                            volume = clip.volume,
                            x = clip.x,
                            y = clip.y,
                            width = clip.width,
                            height = clip.height,
                            zIndex = clip.zIndex,
                            opacity = clip.opacity,
                            segmentTimeUs = clip.segmentTimeUs
                        )
                    )
                    val trimmedDuration = newEndInSource - newStartInSource
                    Log.d(
                        RENDER_TAG,
                        "Added trimmed clip: start=${newStartInSource / 1000}ms, end=${newEndInSource / 1000}ms, duration=${trimmedDuration / 1000}ms"
                    )
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
        Log.d(
            RENDER_TAG,
            "Total duration after global trim: ${totalTrimmedDuration / 1000}ms (target: ${
                globalEndUs?.minus(globalStartUs ?: 0L)?.div(1000)
            }ms)"
        )

        return result
    }
}
