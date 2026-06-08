package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import androidx.media3.common.Effect
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItemSequence
import ch.waio.pro_video_editor.src.features.render.models.AudioTrackConfig
import ch.waio.pro_video_editor.src.features.render.models.RenderConfig
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.File

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
    private val context: Context,
    private val config: RenderConfig
) {

    private var videoEffects: List<Effect> = emptyList()
    private var audioEffects: List<AudioProcessor> = emptyList()

    /**
     * Temporary files (e.g. pre-rendered audio WAVs) created while building
     * the composition. The caller MUST delete these files after the
     * Transformer export finishes (success or failure).
     */
    val temporaryFiles: MutableList<File> = mutableListOf()

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

        val rotationDegrees = (4 - (config.rotateTurns ?: 0)) * 90f

        val hasCustomAudio = config.audioTracks.isNotEmpty()

        // Build video sequence
        val videoBuilder = VideoSequenceBuilder(config.videoClips, context)
            .setVideoEffects(videoEffects)
            .setAudioEffects(audioEffects)
            .setRotation(rotationDegrees)
            .setFlip(config.flipX, config.flipY)
            .setScale(config.scaleX, config.scaleY)
            .setCrop(config.cropWidth, config.cropHeight, config.cropX, config.cropY)
            .setTimedImageLayers(config.imageLayers.map { imageLayer ->
                VideoSequenceBuilder.ImageLayerConfig(
                    imageBytes = imageLayer.imageData,
                    scaleX = config.scaleX,
                    scaleY = config.scaleY,
                    withCropping = config.imageBytesWithCropping,
                    startUs = imageLayer.startUs,
                    endUs = imageLayer.endUs,
                    x = imageLayer.x,
                    y = imageLayer.y,
                    width = imageLayer.width,
                    height = imageLayer.height,
                    animations = imageLayer.animations
                )
            })
            .setEnableAudio(config.enableAudio)
            .setGlobalTrim(config.startUs, config.endUs)
            .setHasCustomAudio(hasCustomAudio)

        // Detect if audio normalization is needed (check both video and custom audio)
        val needsNormalization = videoBuilder.detectAudioNormalizationNeeded() || hasCustomAudio
        videoBuilder.setAudioNormalization(needsNormalization)

        // Video keeps its audio - Media3 will mix it natively with custom audio sequence
        videoBuilder.setForceRemoveAudio(false)

        // Build video sequence (with audio intact)
        val videoSequence = videoBuilder.build()

        // Forward any temp files produced by VideoSequenceBuilder (reversed-segment
        // MP4s) so the render pipeline deletes them after export.
        temporaryFiles.addAll(videoBuilder.temporaryFiles)

        // Prepare sequences list
        val sequences = mutableListOf<EditedMediaItemSequence>()
        sequences.add(videoSequence)
        Log.d(
            RENDER_TAG,
            "Created video EditedMediaItemSequence with ${config.videoClips.size} items"
        )

        // Add audio tracks as separate sequences - Media3 will mix all tracks natively.
        // Each audio track is pre-rendered to a single gap-less PCM WAV file via
        // AudioPreRenderer to avoid encoder frame realignment artifacts (clicks/gaps)
        // at loop and silence boundaries.
        if (hasCustomAudio) {
            val totalVideoDuration = videoBuilder.calculateTotalDuration(config.playbackSpeed)

            for ((index, track) in config.audioTracks.withIndex()) {
                Log.d(
                    RENDER_TAG,
                    "🎵 Pre-rendering audio track $index: path=${track.path}, volume=${track.volume}, loop=${track.loop}"
                )

                val result = AudioSequenceBuilder(context, track.path, totalVideoDuration)
                    .setLoop(track.loop)
                    .setStartTime(track.audioStartUs)
                    .setAudioEndTime(track.audioEndUs)
                    .setCompositionStartTime(track.startUs)
                    .setCompositionEndTime(track.endUs)
                    .build()

                if (result != null) {
                    sequences.add(result.sequence)
                    temporaryFiles.add(result.temporaryFile)
                    Log.d(
                        RENDER_TAG,
                        "Audio track $index pre-rendered to ${result.temporaryFile.name} " +
                                "(${result.temporaryFile.length()} bytes)"
                    )
                }
            }
        }

        // Build final composition
        val composition = Composition.Builder(sequences).build()
        Log.d(RENDER_TAG, "Composition created successfully with ${sequences.size} sequences")

        return composition
    }
}
