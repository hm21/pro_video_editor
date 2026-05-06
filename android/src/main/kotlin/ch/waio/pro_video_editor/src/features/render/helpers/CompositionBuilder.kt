package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.AlphaScale
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import ch.waio.pro_video_editor.src.features.render.models.RenderConfig
import ch.waio.pro_video_editor.src.features.render.models.VideoClip
import ch.waio.pro_video_editor.src.features.render.utils.getRotatedVideoDimensions
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.File
import kotlin.math.max
import kotlin.math.min
import androidx.core.graphics.createBitmap

/**
 * Main builder class for creating Media3 Compositions from render configurations.
 * 
 * Orchestrates video sequences, custom audio tracks, and audio normalization.
 * Uses Media3's native audio mixing for combining video audio with custom audio tracks.
 * This class delegates the actual building to specialized builders 
 * (VideoSequenceBuilder, AudioSequenceBuilder).
 */
@UnstableApi
class CompositionBuilder(
    private val config: RenderConfig,
    private val context: Context
) {

    private var videoEffects: List<Effect> = emptyList()
    private var audioEffects: List<AudioProcessor> = emptyList()

    /**
     * Sets the video effects to apply from EffectsProcessor.
     */
    fun setVideoEffects(effects: List<Effect>): CompositionBuilder {
        this.videoEffects = effects
        return this
    }

    /**
     * Sets the audio effects to apply from EffectsProcessor.
     */
    fun setAudioEffects(effects: List<AudioProcessor>): CompositionBuilder {
        this.audioEffects = effects
        return this
    }

    /**
     * Builds the complete composition with video and optional custom audio tracks.
     * 
     * @return Composition ready for Media3 Transformer, or null if no video clips
     */
    fun build(): Composition? {
        if (config.videoClips.isEmpty()) {
            return null
        }

        Log.d(RENDER_TAG, "Creating composition with ${config.videoClips.size} video clips")
        Log.d(RENDER_TAG, "Audio enabled: ${config.enableAudio}")
        Log.d(RENDER_TAG, "Audio tracks: ${config.audioTracks.size}")

        // Default render dimensions if not provided
        var renderWidth = config.renderWidth
        var renderHeight = config.renderHeight
        val rotationDegrees = (4 - (config.rotateTurns ?: 0)) * 90f

        // If any clip has x, y, width, height, segmentTimeUs, opacity or zIndex, we use multiple sequences.
        val needsMultipleSequences = config.videoClips.any {
            it.x != null || it.y != null || it.width != null || it.height != null || 
            it.segmentTimeUs != null || it.opacity != null || (it.zIndex ?: 0) != 0
        }

        val hasImageLayers = config.imageLayers.isNotEmpty()
        if ((renderWidth == null || renderHeight == null) && (needsMultipleSequences || hasImageLayers)) {
            // Use the first clip for dimensions. 
            // Prefer explicitly set width/height if available, otherwise fallback to file dimensions.
            val backgroundClip = config.videoClips.first()
            if (backgroundClip.width != null && backgroundClip.height != null) {
                renderWidth = backgroundClip.width.toInt()
                renderHeight = backgroundClip.height.toInt()
                Log.d(RENDER_TAG, "Defaulting render dimensions to first clip's size: ${renderWidth}x${renderHeight}")
            } else {
                val (w, h, _) = getRotatedVideoDimensions(File(backgroundClip.inputPath), rotationDegrees)
                renderWidth = w
                renderHeight = h
                Log.d(RENDER_TAG, "Defaulting render dimensions to first clip's file: ${renderWidth}x${renderHeight}")
            }
        }

        Log.d(RENDER_TAG, "Render dimensions: ${renderWidth}x${renderHeight}")

        val hasCustomAudio = config.audioTracks.isNotEmpty()

        // Detect if audio normalization is needed (check both video and custom audio)
        // This MUST be done before building sequences so they all use consistent channel counts.
        // We now rely on pre-transcoding for multi-channel video clips, 
        // so videoNeedsNormalization will usually be false here.
        val videoMetadataBuilder = VideoSequenceBuilder(config.videoClips)
            .setEnableAudio(config.enableAudio)
        val videoNeedsNormalization = videoMetadataBuilder.detectAudioNormalizationNeeded()
        val needsNormalization = videoNeedsNormalization || hasCustomAudio

        // 1. Calculate total duration of the entire composition.
        // Even in complex compositions, some clips might not have segmentTimeUs,
        // in which case they should follow the previous clip in the input list.
        var totalDurationUs = 0L
        var runningSequentialTimeUs = 0L
        
        // Map to store calculated start/end times for each clip by its identity (original index)
        val clipTimings = mutableMapOf<Int, Pair<Long, Long>>()

        for ((index, clip) in config.videoClips.withIndex()) {
            val clipDurationUs = when {
                clip.endUs != null -> clip.endUs - (clip.startUs ?: 0L)
                else -> MediaInfoExtractor.getVideoDuration(clip.inputPath) - (clip.startUs ?: 0L)
            }

            val clipStartInComposition = if (needsMultipleSequences) {
                clip.segmentTimeUs ?: runningSequentialTimeUs
            } else {
                runningSequentialTimeUs
            }
            
            val clipEndInComposition = clipStartInComposition + clipDurationUs
            clipTimings[index] = Pair(clipStartInComposition, clipEndInComposition)
            
            totalDurationUs = max(totalDurationUs, clipEndInComposition)
            
            // Sequential time only increments if we are NOT using explicit segment timing,
            // or if we are in sequential mode.
            if (!needsMultipleSequences || clip.segmentTimeUs == null) {
                runningSequentialTimeUs = clipEndInComposition
            }
        }
        
        // Calculate global timing
        val globalStartUs = config.startUs ?: 0L
        val globalEndUs = config.endUs ?: totalDurationUs
        val globalDurationUs = globalEndUs - globalStartUs
        
        Log.d(RENDER_TAG, "Total composition duration: ${totalDurationUs / 1000}ms")
        Log.d(RENDER_TAG, "Global trim: ${globalStartUs / 1000}ms to ${globalEndUs / 1000}ms (duration: ${globalDurationUs / 1000}ms)")

        val sequences = mutableListOf<EditedMediaItemSequence>()

        if (needsMultipleSequences) {
            Log.d(RENDER_TAG, "Complex composition detected, building multiple video sequences")

            // 3. Sort clips for correct layering based on zIndex and original order.
            // Rules:
            // 1. Higher zIndex on top.
            // 2. Default zIndex is 0.
            // 3. If zIndex is same, latter segment in input list is on top.
            //
            // In Media3, the first sequence in the list is the BOTTOM-MOST layer (Index 0).
            // By using a stable ascending sort, we satisfy the rules.
            val indexedClips = config.videoClips.mapIndexed { index, clip -> index to clip }
            val sortedIndexedClips = indexedClips.sortedByDescending { it.second.zIndex ?: 0 }

            Log.d(RENDER_TAG, "Sorted clips for composition (top to bottom):")
            for ((index, clip) in sortedIndexedClips) {
                Log.d(RENDER_TAG, "  Sequence ${index + 1}: path=${clip.inputPath}, zIndex=${clip.zIndex ?: 0}")

                val (clipStartUs, clipEndUs) = clipTimings[index]!!

                // Check if clip overlaps with global trim range
                if (clipEndUs <= globalStartUs || clipStartUs >= globalEndUs) {
                    Log.d(RENDER_TAG, "Skipping clip outside global trim: ${clip.inputPath}")
                    continue
                }

                // Adjust clip boundaries and calculate leading gap
                val adjustedStartInComposition = max(clipStartUs, globalStartUs)
                val adjustedEndInComposition = min(clipEndUs, globalEndUs)
                val leadingGapUs = adjustedStartInComposition - globalStartUs
                
                // Adjust trim relative to source
                var clipTrimStartUs = clip.startUs ?: 0L
                if (clipStartUs < globalStartUs) {
                    clipTrimStartUs += (globalStartUs - clipStartUs)
                }
                val clipTrimEndUs = clipTrimStartUs + (adjustedEndInComposition - adjustedStartInComposition)

                // Build sequence with pre-trimmed clip
                val trimmedClip = clip.copy(startUs = clipTrimStartUs, endUs = clipTrimEndUs)
                val videoBuilder = VideoSequenceBuilder(listOf(trimmedClip))
                    .setVideoEffects(emptyList())
                    .setAudioEffects(emptyList())
                    .setRotation(rotationDegrees)
                    .setFlip(config.flipX, config.flipY)
                    .setScale(config.scaleX, config.scaleY)
                    .setCrop(config.cropWidth, config.cropHeight, config.cropX, config.cropY)
                    .setEnableAudio(config.enableAudio && (clip.volume ?: 1.0f) > 0 && !hasCustomAudio)
                    .setHasCustomAudio(hasCustomAudio)
                    .setForceRemoveAudio(false)
                    .setRenderDimensions(renderWidth, renderHeight)
                    // Ensure consistency across multiple sequences in complex compositions.
                    .setAudioNormalization(needsNormalization)
                
                val baseSequence = videoBuilder.build()
                val sequenceBuilder = EditedMediaItemSequence.Builder(baseSequence.trackTypes)

                // Prepend leading gap relative to globalStartUs
                if (leadingGapUs > 0) {
                    sequenceBuilder.addItem(createTransparentGapItem(leadingGapUs, renderWidth, renderHeight))
                }
                
                sequenceBuilder.addItems(baseSequence.editedMediaItems)

                // Pad remaining duration to prevent frozen frames
                val sequenceDurationUs = leadingGapUs + (adjustedEndInComposition - adjustedStartInComposition)
                if (sequenceDurationUs < globalDurationUs) {
                    sequenceBuilder.addItem(createTransparentGapItem(globalDurationUs - sequenceDurationUs, renderWidth, renderHeight))
                }
                
                sequences.add(sequenceBuilder.build())
            }
        } else {
            // Build single optimized video sequence
            val videoBuilder = createVideoBuilder(config.videoClips, rotationDegrees, hasCustomAudio)
                .setVideoEffects(emptyList())
                .setAudioEffects(emptyList())
                .setRenderDimensions(renderWidth, renderHeight)
                .setAudioNormalization(needsNormalization)
            sequences.add(videoBuilder.build())
        }

        // Add audio tracks as separate sequences - Media3 will mix all tracks natively
        if (hasCustomAudio) {
            for ((index, track) in config.audioTracks.withIndex()) {
                Log.d(
                    RENDER_TAG,
                    "🎵 Adding audio track $index: path=${track.path}, volume=${track.volume}, loop=${track.loop}"
                )

                val audioSequence = AudioSequenceBuilder(track.path, globalDurationUs)
                    .setVolume(track.volume)
                    .setNormalization(false) // Custom tracks are usually stereo; allow native resampling
                    .setLoop(track.loop)
                    .setStartTime(track.audioStartUs)
                    .setAudioEndTime(track.audioEndUs)
                    .setCompositionStartTime(track.startUs)
                    .setCompositionEndTime(track.endUs)
                    .build()

                if (audioSequence != null) {
                    sequences.add(audioSequence)
                    Log.d(RENDER_TAG, "Audio track $index added (will be mixed natively by Media3)")
                }
            }
        }

        // Build final composition
        val compositionBuilder = Composition.Builder(sequences.toList())
        
        // Add Global effects and Presentation effect.
        // Moving effects to Composition level ensures they apply to the final combined video.
        val combinedVideoEffects = mutableListOf<Effect>()
        combinedVideoEffects.addAll(videoEffects)

        // Apply Image Layers at the Composition level so they are truly global
        if (config.imageLayers.isNotEmpty() && renderWidth != null && renderHeight != null) {
            applyTimedImageLayers(
                combinedVideoEffects, 
                config.imageLayers, 
                renderWidth, 
                renderHeight
            )
        }

        if (renderWidth != null && renderHeight != null) {
            combinedVideoEffects += Presentation.createForWidthAndHeight(
                renderWidth,
                renderHeight,
                Presentation.LAYOUT_SCALE_TO_FIT
            )
            Log.d(RENDER_TAG, "Global Presentation effect applied: ${renderWidth}x${renderHeight}")
        }

        // Prepare global audio effects
        val finalAudioEffects = mutableListOf<AudioProcessor>()
        finalAudioEffects.addAll(audioEffects)

        compositionBuilder.setEffects(Effects(finalAudioEffects, combinedVideoEffects))

        val composition = compositionBuilder.build()
        Log.d(RENDER_TAG, "Composition created successfully with ${sequences.size} sequences")

        return composition
    }

    /**
     * Cleans up temporary resources used during composition building.
     */
    fun release() {
        // No temporary files to cleanup in current implementation
    }

    private fun createTransparentGapItem(durationUs: Long, renderWidth: Int?, renderHeight: Int?): EditedMediaItem {
        val gapFile = File(context.cacheDir, "pve_transparent_gap.png")
        if (!gapFile.exists()) {
            try {
                val bitmap = createBitmap(1, 1)
                bitmap.eraseColor(Color.TRANSPARENT)
                gapFile.outputStream().use {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) 
                }
                Log.d(RENDER_TAG, "Created transparent gap PNG at: ${gapFile.absolutePath}")
            } catch (e: Exception) {
                Log.e(RENDER_TAG, "Failed to create transparent gap PNG: ${e.message}")
            }
        }

        val mediaItem = MediaItem.Builder()
            .setUri(Uri.fromFile(gapFile))
            .setImageDurationMs(maxOf(1, (durationUs + 999) / 1000))
            .build()

        val videoEffects = mutableListOf<Effect>()
        videoEffects.add(AlphaScale(0f))
        
        // Move the gap item off-screen to ensure it doesn't obscure anything even if transparency fails
        if (renderWidth != null && renderHeight != null) {
            videoEffects.add(VideoCompositionTransformation(
                x = -100.0, // Off-screen
                y = -100.0,
                width = 1.0,
                height = 1.0,
                videoWidth = 1,
                videoHeight = 1,
                renderWidth = renderWidth,
                renderHeight = renderHeight
            ))
        }

        return EditedMediaItem.Builder(mediaItem)
            .setFrameRate(30)
            .setEffects(Effects(emptyList(), videoEffects))
            .build()
    }

    private fun createVideoBuilder(
        clips: List<VideoClip>,
        rotationDegrees: Float,
        hasCustomAudio: Boolean
    ): VideoSequenceBuilder {
        return VideoSequenceBuilder(clips)
            .setVideoEffects(videoEffects)
            .setAudioEffects(audioEffects)
            .setRotation(rotationDegrees)
            .setFlip(config.flipX, config.flipY)
            .setScale(config.scaleX, config.scaleY)
            .setCrop(config.cropWidth, config.cropHeight, config.cropX, config.cropY)
            .setEnableAudio(config.enableAudio)
            .setGlobalTrim(config.startUs, config.endUs)
            .setHasCustomAudio(hasCustomAudio)
            .setForceRemoveAudio(false)
    }
}
