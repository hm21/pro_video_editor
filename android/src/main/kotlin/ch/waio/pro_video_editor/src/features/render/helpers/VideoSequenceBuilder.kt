package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.net.Uri
import applyChromaKey
import applyScale
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.SpeedChangeEffect
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import ch.waio.pro_video_editor.src.features.render.models.ChromaKeyConfig
import ch.waio.pro_video_editor.src.features.render.models.LayerAnimationConfig
import ch.waio.pro_video_editor.src.features.render.models.VideoClip
import ch.waio.pro_video_editor.src.features.render.utils.getRotatedVideoDimensions
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import ch.waio.pro_video_editor.src.shared.media.EncodedImage
import java.io.File

/**
 * Builder class for creating video sequences with effects in video compositions.
 *
 * Handles multiple video clips, effects, audio normalization, volume control,
 * cropping, and image overlays.
 */
@UnstableApi
class VideoSequenceBuilder(
    private val videoClips: List<VideoClip>,
    private val context: Context? = null,
) {
    /**
     * Paths to temp files produced while building the sequence (currently:
     * reversed-segment MP4s pre-rendered by [VideoReverser]). The caller MUST
     * delete these after the Transformer export finishes.
     */
    val temporaryFiles: MutableList<java.io.File> = mutableListOf()

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
    private var globalPlaybackSpeed: Float? = null
    private var hasCustomAudio: Boolean = false
    private var scaleX: Float? = null
    private var scaleY: Float? = null
    private var outputWidth: Int? = null
    private var outputHeight: Int? = null
    private var globalChromaKey: ChromaKeyConfig? = null
    private val rotatedDimensionsCache = mutableMapOf<String, Triple<Int, Int, Int>>()

    data class CropConfig(
        val width: Int?,
        val height: Int?,
        val x: Int?,
        val y: Int?
    )

    data class ImageLayerConfig(
        val image: EncodedImage?,
        val scaleX: Float?,
        val scaleY: Float?,
        val withCropping: Boolean = false,
        val startUs: Long = 0,
        val endUs: Long = -1,
        val x: Int? = null,
        val y: Int? = null,
        val width: Double? = null,
        val height: Double? = null,
        /** Clockwise rotation around the layer center, in radians. */
        val rotation: Double = 0.0,
        /** Whether an animated image (GIF) repeats while the layer is visible. */
        val loop: Boolean = true,
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
     * Sets the chroma key applied to every clip that carries none of its own.
     *
     * A [VideoClip.chromaKey] overrides this per clip; the two are never merged.
     */
    fun setChromaKey(chromaKey: ChromaKeyConfig?): VideoSequenceBuilder {
        this.globalChromaKey = chromaKey
        return this
    }

    /**
     * Sets the exact output canvas size. When set, each clip is scaled to fit
     * inside it (preserving aspect ratio), centered, and padded with black.
     */
    fun setOutputResolution(width: Int?, height: Int?): VideoSequenceBuilder {
        this.outputWidth = width
        this.outputHeight = height
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
     * Sets the composition-wide playback speed.
     *
     * The global trim window is expressed in OUTPUT time, so [applyGlobalTrim]
     * needs the composition-wide speed (combined with each clip's own
     * [VideoClip.playbackSpeed]) to map the trim onto the source timeline.
     *
     * @param speed Speed multiplier applied to the whole composition (null/<=0 = 1x)
     */
    fun setGlobalPlaybackSpeed(speed: Float?): VideoSequenceBuilder {
        this.globalPlaybackSpeed = speed
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
     * Calculates total duration of all video clips combined after global trim.
     * Playback speed is included so parallel custom audio sequences are
     * constrained to the rendered video timeline, not the source timeline.
     *
     * Uses the composition-wide speed set via [setGlobalPlaybackSpeed].
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
            }.coerceAtLeast(0L)
            totalDurationUs += VideoTimelineDurationCalculator.renderedClipDurationUs(
                sourceDurationUs = clipDurationUs,
                clipPlaybackSpeed = clip.playbackSpeed,
                globalPlaybackSpeed = globalPlaybackSpeed
            )
        }
        Log.d(
            RENDER_TAG,
            "Total rendered video duration (after trim/speed): ${totalDurationUs / 1000} ms"
        )
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

        // Resolve layers that run "until the end" (endUs == -1) with an out-phase
        // animation to a concrete end so their animateOut can play. Only for a
        // single-clip sequence, where "until end" == that clip's output duration
        // is unambiguous; multi-clip sequences keep their prior behavior.
        if (timelineClips.size == 1) {
            timedImageLayers = resolveOpenEndedOutAnimations(
                timedImageLayers, clipOutputDurationUs(timelineClips[0])
            )
        }

        // Prepare normalized audio effects with channel mixing if needed
        val normalizedAudioEffects = if (needsAudioNormalization) {
            Log.d(RENDER_TAG, "Adding ChannelMixingAudioProcessor to normalize audio to stereo")
            buildChannelNormalizationEffects()
        } else {
            audioEffects.toList()
        }

        // Compute per-clip fade-to-black windows from clip transitions.
        val fadeInfos = computeFadeInfos(timelineClips)

        // Build EditedMediaItems for each clip
        val editedMediaItems = timelineClips.mapIndexed { index, clip ->
            buildEditedMediaItem(index, clip, normalizedAudioEffects, fadeInfos[index])
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
     * Per-clip dip (fade-to-black / fade-to-white) windows, expressed in
     * output-local time.
     *
     * @property clipDurationUs Output duration of the clip (after per-clip speed)
     * @property fadeInUs Fade-in-from-color window at the clip's head (0 = none)
     * @property fadeOutUs Fade-out-to-color window at the clip's tail (0 = none)
     * @property curve Easing curve for the fade
     * @property dipColor ARGB color the clip dips to/from
     */
    private data class ClipFadeInfo(
        val clipDurationUs: Long,
        val fadeInUs: Long,
        val fadeOutUs: Long,
        val curve: String,
        val dipColor: Int
    )

    /** Returns the dip color for a "fadeTo*" transition, or null otherwise. */
    private fun dipColorFor(transition: ch.waio.pro_video_editor.src.features
        .render.models.TransitionConfig?): Int? = when (transition?.type) {
        "fadeToBlack" -> android.graphics.Color.BLACK
        "fadeToWhite" -> android.graphics.Color.WHITE
        else -> null
    }

    /**
     * Source duration of a clip after trimming (microseconds).
     */
    private fun clipSourceDurationUs(clip: VideoClip): Long {
        return when {
            clip.endUs != null && clip.startUs != null -> clip.endUs - clip.startUs
            clip.endUs != null -> clip.endUs
            else -> MediaInfoExtractor.getVideoDuration(clip.inputPath)
        }.coerceAtLeast(0L)
    }

    /**
     * Output duration of a clip after per-clip playback speed (microseconds).
     */
    private fun clipOutputDurationUs(clip: VideoClip): Long {
        val src = clipSourceDurationUs(clip)
        val speed = clip.playbackSpeed?.takeIf { it > 0f } ?: 1.0f
        return (src / speed).toLong()
    }

    /**
     * Computes dip (fade-to-black / fade-to-white) windows for each timeline
     * clip.
     *
     * A `fadeToBlack`/`fadeToWhite` transition on clip *i* dips the boundary
     * between clip *i* and *i+1*: clip *i* fades out to the color over its last
     * `duration/2`, and clip *i+1* fades in from the color over its first
     * `duration/2`. Overlap transitions (dissolve/slide/push/wipe) are handled
     * separately by [ClipTransitionRenderer] and never reach this method.
     *
     * A dip transition on the **last** clip is the loop wrap: it fades that clip
     * out to the color at the very end AND fades the **first** clip in from the
     * color at the very start, so a looping player dips through the color at the
     * restart seam. (Overlap wraps are baked into an appended blend clip by
     * [ClipTransitionRenderer], so by the time they reach here the last entry is
     * that blend and carries no transition.)
     */
    private fun computeFadeInfos(clips: List<VideoClip>): List<ClipFadeInfo?> {
        return clips.indices.map { i ->
            val clip = clips[i]
            val prev = clips.getOrNull(i - 1)
            // The first clip has no previous clip; its fade-in is seeded by the
            // loop wrap (the last clip's dip transition) instead.
            val incomingTransition =
                prev?.transition ?: if (i == 0) clips.lastOrNull()?.transition else null

            val outgoingColor = dipColorFor(clip.transition)
            val incomingColor = dipColorFor(incomingTransition)

            val outgoingUs = if (outgoingColor != null) clip.transition!!.durationUs else 0L
            val incomingUs = if (incomingColor != null) incomingTransition!!.durationUs else 0L

            if (outgoingColor == null && incomingColor == null) {
                null
            } else {
                val outDur = clipOutputDurationUs(clip)
                // When a clip both ends and starts with a dip, the outgoing
                // (this clip's) transition wins for color/curve.
                val curve = if (outgoingColor != null) {
                    clip.transition!!.curve
                } else {
                    incomingTransition!!.curve
                }
                ClipFadeInfo(
                    clipDurationUs = outDur,
                    fadeInUs = (incomingUs / 2).coerceAtMost(outDur),
                    fadeOutUs = (outgoingUs / 2).coerceAtMost(outDur),
                    curve = curve,
                    dipColor = outgoingColor ?: incomingColor!!
                )
            }
        }
    }

    /**
     * Builds an EditedMediaItem for a single video clip with all effects.
     */
    private fun buildEditedMediaItem(
        index: Int,
        clip: VideoClip,
        normalizedAudioEffects: List<AudioProcessor>,
        fadeInfo: ClipFadeInfo?
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

        // Chroma key first, so it sees the original decoded colors — before
        // rotation, flip, the color LUT and blur. A clip's own key wins over
        // the global one; they are never merged.
        //
        // flattenTransparency is on because this is the single-track path:
        // there is no layer underneath, so a key without a background is filled
        // with opaque black instead (see applyChromaKey for why).
        applyChromaKey(
            clipVideoEffects,
            if (clip.suppressChromaKey) null else clip.chromaKey ?: globalChromaKey,
            flattenTransparency = true,
        )

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
            applyTimedImageLayers(
                clipVideoEffects, timedImageLayers, videoWidth, videoHeight,
                outputWidth, outputHeight
            )
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
            applyTimedImageLayers(
                clipVideoEffects, timedImageLayers, videoWidth, videoHeight,
                outputWidth, outputHeight
            )
        }

        // Apply scale AFTER overlay and crop to match the iOS/macOS pipeline.
        // This prevents the overlay from being distorted by a pre-applied scale.
        applyScale(clipVideoEffects, scaleX, scaleY)

        // Letterbox to the exact output canvas (after scale/crop/overlay) when a
        // custom resolution was requested. SCALE_TO_FIT preserves aspect ratio
        // and pads the remaining space with black.
        val outW = outputWidth
        val outH = outputHeight
        if (outW != null && outH != null) {
            clipVideoEffects += Presentation.createForWidthAndHeight(
                outW, outH, Presentation.LAYOUT_SCALE_TO_FIT
            )
        }

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

        // Attach the dip (fade-to-black/white) overlay LAST so the entire
        // composed frame — including any image-layer overlays — dips to the
        // transition color at the clip boundary. The overlay is added after
        // scale, so size the solid-color bitmap to cover the post-scale frame
        // (centered, oversized overflow is clipped by Media3).
        fadeInfo?.let { info ->
            val sx = scaleX ?: 1f
            val sy = scaleY ?: 1f
            val dipW = maxOf(videoWidth, (videoWidth * sx).toInt())
            val dipH = maxOf(videoHeight, (videoHeight * sy).toInt())
            clipVideoEffects += OverlayEffect(
                listOf(
                    ClipFadeOverlay(
                        videoWidth = dipW,
                        videoHeight = dipH,
                        dipColor = info.dipColor,
                        clipDurationUs = info.clipDurationUs,
                        fadeInUs = info.fadeInUs,
                        fadeOutUs = info.fadeOutUs,
                        curve = info.curve,
                    )
                )
            )
            Log.d(
                RENDER_TAG,
                "Clip $index dip transition: fadeInUs=${info.fadeInUs}, " +
                        "fadeOutUs=${info.fadeOutUs}, color=${info.dipColor}"
            )
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
            "Applying global trim: start=${globalStartUs?.div(1000)}ms, " +
                    "end=${globalEndUs?.div(1000)}ms, globalSpeed=$globalPlaybackSpeed"
        )

        // Resolve each clip's source range here (MediaInfoExtractor is Android-only)
        // and hand pure values to the dependency-free calculator, which resolves the
        // trim against the OUTPUT (post-speed) timeline and maps it back to source.
        val inputs = clips.map { clip ->
            VideoGlobalTrimCalculator.ClipInput(
                sourceStartUs = clip.startUs ?: 0L,
                sourceEndUs = clip.endUs ?: MediaInfoExtractor.getVideoDuration(clip.inputPath),
                playbackSpeed = clip.playbackSpeed,
                reverseVideo = clip.reverseVideo,
            )
        }

        val trims = VideoGlobalTrimCalculator.applyGlobalTrim(
            clips = inputs,
            globalStartUs = globalStartUs,
            globalEndUs = globalEndUs,
            globalPlaybackSpeed = globalPlaybackSpeed,
        )

        val result = mutableListOf<VideoClip>()
        clips.forEachIndexed { index, clip ->
            val trim = trims[index]
            if (trim == null) {
                Log.d(RENDER_TAG, "Skipping clip (outside global trim range): ${clip.inputPath}")
            } else {
                result.add(clip.copy(startUs = trim.sourceStartUs, endUs = trim.sourceEndUs))
                Log.d(
                    RENDER_TAG,
                    "Added trimmed clip: start=${trim.sourceStartUs / 1000}ms, " +
                            "end=${trim.sourceEndUs / 1000}ms, " +
                            "duration=${(trim.sourceEndUs - trim.sourceStartUs) / 1000}ms"
                )
            }
        }

        return result
    }

    /**
     * Materializes any clip still flagged as reversed. In normal operation
     * [RenderVideo] pre-renders reversed clips BEFORE the sequence is built
     * (so it can report progress on the slow MediaCodec pre-render). This
     * fallback only triggers if a reversed clip somehow reaches the builder
     * directly (e.g. tests bypassing [RenderVideo]).
     */
    private fun expandReversedClips(clips: List<VideoClip>): List<VideoClip> {
        if (clips.none { it.reverseVideo }) return clips
        val ctx = context
        if (ctx == null) {
            Log.w(
                RENDER_TAG,
                "Reverse requested but no Context provided to VideoSequenceBuilder; " +
                        "leaving clips unchanged."
            )
            return clips
        }
        Log.w(
            RENDER_TAG,
            "Reversed clip reached VideoSequenceBuilder — pre-render fallback engaged " +
                    "(progress will NOT be reported for this stage)."
        )

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
            try {
                val reversed = VideoReverser.reverseSync(
                    context = ctx,
                    inputPath = clip.inputPath,
                    segmentStartUs = sourceStartUs,
                    segmentEndUs = sourceEndUs,
                    includeAudio = enableAudio && (clip.volume ?: 1.0f) > 0f,
                )
                temporaryFiles.add(java.io.File(reversed.outputPath))
                result.add(
                    clip.copy(
                        inputPath = reversed.outputPath,
                        startUs = 0L,
                        endUs = reversed.durationUs.takeIf { it > 0 },
                        reverseVideo = false
                    )
                )
            } catch (e: Exception) {
                Log.e(
                    RENDER_TAG,
                    "Reverse pre-render failed for ${clip.inputPath}: ${e.message}. " +
                            "Falling back to forward playback."
                )
                result.add(clip.copy(reverseVideo = false))
            }
        }
        return result
    }
}
