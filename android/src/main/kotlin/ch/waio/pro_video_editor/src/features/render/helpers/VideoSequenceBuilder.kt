package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.net.Uri
import applyScale
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.SpeedChangeEffect
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
    private var timedImageLayers: List<ImageLayerConfig> = emptyList()
    private var enableAudio: Boolean = true
    private var needsAudioNormalization: Boolean = false
    private var forceRemoveAudio: Boolean = false
    private var globalStartUs: Long? = null
    private var globalEndUs: Long? = null
    private var hasCustomAudio: Boolean = false
    private var scaleX: Float? = null
    private var scaleY: Float? = null
    private val rotatedDimensionsCache = mutableMapOf<String, Triple<Int, Int, Int>>()

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
        val withCropping: Boolean = false,
        val startUs: Long = 0,
        val endUs: Long = -1,
        val x: Int? = null,
        val y: Int? = null,
        val width: Double? = null,
        val height: Double? = null,
        val animations: List<LayerAnimationConfig> = emptyList()
    )

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
     * Sets time-based image layer overlays configuration.
     */
    fun setTimedImageLayers(layers: List<ImageLayerConfig>): VideoSequenceBuilder {
        this.timedImageLayers = layers
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
        val timelineClips = expandReversedClips(trimmedClips)
        Log.d(RENDER_TAG, "After reverse expansion: ${timelineClips.size} timeline clips")

        // Prepare normalized audio effects with channel mixing if needed
        val normalizedAudioEffects = if (needsAudioNormalization) {
            Log.d(RENDER_TAG, "Adding ChannelMixingAudioProcessor to normalize audio to stereo")
            buildChannelNormalizationEffects()
        } else {
            audioEffects.toList()
        }

        // Build EditedMediaItems for each clip
        val editedMediaItems = timelineClips.mapIndexed { index, clip ->
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

        // Determine track types for the sequence
        val trackTypes = mutableSetOf<@C.TrackType Int>(C.TRACK_TYPE_VIDEO)
        if (enableAudio) {
            trackTypes.add(C.TRACK_TYPE_AUDIO)
        }

        return EditedMediaItemSequence.Builder(trackTypes)
            .addItems(finalVideoItems)
            .setIsLooping(false)
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
            1.0f * boost,
            0.0f,
            0.707f * boost,
            0.0f,
            0.707f * boost,
            0.0f,
            0.707f * boost,
            0.0f,  // Left output
            0.0f,
            1.0f * boost,
            0.707f * boost,
            0.0f,
            0.0f,
            0.707f * boost,
            0.0f,
            0.707f * boost   // Right output
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
            ChannelMixingMatrix.createForConstantGain(2, 2)
        )

        // Mono (1 channel) to Stereo (2 channels)
        channelMixer.putChannelMixingMatrix(
            ChannelMixingMatrix.createForConstantGain(1, 2)
        )

        Log.d(
            RENDER_TAG,
            "Channel normalization configured with boosted coefficients for loudness preservation"
        )

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
            val startUs = clip.startUs ?: 0L
            val endUs = clip.endUs ?: C.TIME_END_OF_SOURCE
            val expectedDurationMs = if (clip.endUs != null && clip.startUs != null) {
                (clip.endUs - clip.startUs) / 1000
            } else if (clip.endUs != null) {
                clip.endUs / 1000
            } else {
                -1L
            }

            Log.d(
                RENDER_TAG,
                "Applying trim to clip ${clip.inputPath}: start=${startUs / 1000} ms, end=${if (endUs == C.TIME_END_OF_SOURCE) "source end" else "${endUs / 1000} ms"}, expectedDuration=$expectedDurationMs ms"
            )

            val clippingConfigBuilder = MediaItem.ClippingConfiguration.Builder()
                .setStartPositionUs(startUs)
            if (clip.endUs != null) {
                clippingConfigBuilder.setEndPositionUs(clip.endUs)
            } else {
                clippingConfigBuilder.setEndPositionMs(C.TIME_END_OF_SOURCE)
            }
            val clippingConfig = clippingConfigBuilder.build()

            mediaItemBuilder.setClippingConfiguration(clippingConfig)
        }

        val mediaItem = mediaItemBuilder.build()

        // Build video effects
        val clipVideoEffects = mutableListOf<Effect>()
        clipVideoEffects.addAll(videoEffects)

        // Calculate video dimensions for image layer positioning
        // This must be done before applying any effects
        val dimensionsKey = "${inputFile.absolutePath}|$rotationDegrees"
        val dimensions = rotatedDimensionsCache.getOrPut(dimensionsKey) {
            getRotatedVideoDimensions(inputFile, rotationDegrees)
        }
        var videoWidth = dimensions.first
        var videoHeight = dimensions.second
        val videoRotation = dimensions.third

        // Adjust dimensions based on rotation
        val isRotated90Deg = videoRotation == 90 || videoRotation == 270

        // If crop is applied, update dimensions for AFTER crop scenario
        val croppedWidth: Int?
        val croppedHeight: Int?
        val crop = cropConfig
        if (crop != null) {
            croppedWidth = if (isRotated90Deg) crop.height else crop.width
            croppedHeight = if (isRotated90Deg) crop.width else crop.height
        } else {
            croppedWidth = null
            croppedHeight = null
        }

        // Apply timed image layers BEFORE crop if withCropping is enabled
        // This makes the images get cropped together with the video
        val hasWithCropping = timedImageLayers.any { it.withCropping }
        if (hasWithCropping && timedImageLayers.isNotEmpty()) {
            applyTimedImageLayers(clipVideoEffects, timedImageLayers, videoWidth, videoHeight)
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

            // Update dimensions after crop for image layers applied AFTER crop
            if (croppedWidth != null) videoWidth = croppedWidth
            if (croppedHeight != null) videoHeight = croppedHeight
        }

        // Apply timed image layers AFTER crop if withCropping is disabled (default)
        // This makes the images stretch to the final cropped size
        if (!hasWithCropping && timedImageLayers.isNotEmpty()) {
            applyTimedImageLayers(clipVideoEffects, timedImageLayers, videoWidth, videoHeight)
        }

        // Apply scale AFTER overlay and crop to match the iOS/macOS pipeline.
        // This prevents the overlay from being distorted by a pre-applied scale.
        applyScale(clipVideoEffects, scaleX, scaleY)

        // Per-clip volume control:
        // - Without custom audio: VolumeAudioProcessor per clip works (single sequence)
        // - With custom audio: AudioProcessors don't work with parallel sequences,
        //   so per-clip volume is best-effort (applied via VolumeControlAudioMixer globally)
        val clipVolume = clip.volume
        val perClipAudioProcessors = mutableListOf<AudioProcessor>().apply {
            addAll(normalizedAudioEffects)
            if (!hasCustomAudio && clipVolume != null && clipVolume != 1.0f) {
                Log.d(
                    RENDER_TAG,
                    "Clip $index volume: ${clipVolume}x (applied via VolumeAudioProcessor)"
                )
                add(VolumeAudioProcessor(clipVolume))
            }
        }

        // Per-clip playback speed:
        // - Video: SpeedChangeEffect on the EditedMediaItem
        // - Audio: SonicAudioProcessor (only effective without custom audio /
        //   parallel sequences; otherwise best-effort)
        val clipSpeed = clip.playbackSpeed
        val finalAudioEffects: List<AudioProcessor> = if (clipSpeed != null && clipSpeed > 0f && clipSpeed != 1.0f) {
            Log.d(RENDER_TAG, "Clip $index playback speed: ${clipSpeed}x")
            clipVideoEffects += SpeedChangeEffect(clipSpeed)
            perClipAudioProcessors.apply {
                add(SonicAudioProcessor().apply { setSpeed(clipSpeed) })
            }
        } else {
            perClipAudioProcessors
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
                val startTrimOffsetUs = if (clipStartInComposition < globalStart) {
                    globalStart - clipStartInComposition
                } else {
                    0L
                }
                val endTrimOffsetUs = if (clipEndInComposition > globalEnd) {
                    clipEndInComposition - globalEnd
                } else {
                    0L
                }
                val frameCompensationUs = 33333L // ~33ms = 1 frame at 30fps

                // Adjust start if global start cuts into this clip
                if (startTrimOffsetUs > 0L) {
                    if (clip.reverseVideo) {
                        newEndInSource = clipEndInSource - startTrimOffsetUs
                        Log.d(
                            RENDER_TAG,
                            "Adjusting reversed clip source end by ${startTrimOffsetUs / 1000}ms"
                        )
                    } else {
                        newStartInSource = clipStartInSource + startTrimOffsetUs
                        Log.d(RENDER_TAG, "Adjusting clip start by ${startTrimOffsetUs / 1000}ms")
                    }
                }

                // Adjust end if global end cuts into this clip
                if (endTrimOffsetUs > 0L) {
                    // Subtract ~1 frame to ensure encoder doesn't overshoot. This compensates
                    // for encoder rounding to next frame/audio sample boundary.
                    if (clip.reverseVideo) {
                        newStartInSource = minOf(
                            newEndInSource,
                            newStartInSource + endTrimOffsetUs + frameCompensationUs
                        )
                        Log.d(
                            RENDER_TAG,
                            "Adjusting reversed clip source start by ${endTrimOffsetUs / 1000}ms (with frame compensation)"
                        )
                    } else {
                        newEndInSource = maxOf(
                            newStartInSource,
                            newEndInSource - endTrimOffsetUs - frameCompensationUs
                        )
                        Log.d(
                            RENDER_TAG,
                            "Adjusting clip end by ${endTrimOffsetUs / 1000}ms (with frame compensation)"
                        )
                    }
                }

                // Only add if there's still content left
                if (newEndInSource > newStartInSource) {
                    result.add(
                        VideoClip(
                            inputPath = clip.inputPath,
                            startUs = newStartInSource,
                            endUs = newEndInSource,
                            volume = clip.volume,
                            playbackSpeed = clip.playbackSpeed,
                            reverseVideo = clip.reverseVideo
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

    /**
     * Expands reversed clips into frame-sized forward slices ordered from end to start.
     *
     * Media3 Transformer does not provide a native negative-speed effect. Small slices
     * preserve the existing effect pipeline while producing backwards visual playback.
     */
    private fun expandReversedClips(clips: List<VideoClip>): List<VideoClip> {
        val result = mutableListOf<VideoClip>()

        for (clip in clips) {
            if (!clip.reverseVideo) {
                result.add(clip)
                continue
            }

            val sourceStartUs = clip.startUs ?: 0L
            val sourceEndUs = clip.endUs ?: MediaInfoExtractor.getVideoDuration(clip.inputPath)
            if (sourceEndUs <= sourceStartUs) {
                Log.w(RENDER_TAG, "Skipping reversed clip with invalid range: ${clip.inputPath}")
                continue
            }

            val frameRate = MediaInfoExtractor.getVideoFrameRate(clip.inputPath)
                ?.takeIf { it > 0f }
                ?: 30f
            val frameDurationUs = (1_000_000f / frameRate).toLong().coerceAtLeast(1L)
            var cursorEndUs = sourceEndUs
            var sliceCount = 0

            while (cursorEndUs > sourceStartUs) {
                val sliceStartUs = maxOf(sourceStartUs, cursorEndUs - frameDurationUs)
                result.add(
                    VideoClip(
                        inputPath = clip.inputPath,
                        startUs = sliceStartUs,
                        endUs = cursorEndUs,
                        volume = clip.volume,
                        playbackSpeed = clip.playbackSpeed,
                        reverseVideo = false
                    )
                )
                cursorEndUs = sliceStartUs
                sliceCount++
            }

            Log.d(
                RENDER_TAG,
                "Expanded reversed clip into $sliceCount slices at ${frameRate}fps: ${clip.inputPath}"
            )
        }

        return result
    }
}
