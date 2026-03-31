package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.util.Log
import androidx.media3.common.Effect
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItemSequence
import ch.waio.pro_video_editor.src.features.render.models.AudioTrackConfig
import ch.waio.pro_video_editor.src.features.render.models.RenderConfig

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
        val videoBuilder = VideoSequenceBuilder(config.videoClips)
            .setVideoEffects(videoEffects)
            .setAudioEffects(audioEffects)
            .setRotation(rotationDegrees)
            .setFlip(config.flipX, config.flipY)
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

        // Prepare sequences list
        val sequences = mutableListOf<EditedMediaItemSequence>()
        sequences.add(videoSequence)
        Log.d(
            RENDER_TAG,
            "Created video EditedMediaItemSequence with ${config.videoClips.size} items"
        )

        // Add audio tracks as separate sequences - Media3 will mix all tracks natively
        if (hasCustomAudio) {
            val totalVideoDuration = videoBuilder.calculateTotalDuration()

            for ((index, track) in config.audioTracks.withIndex()) {
                Log.d(
                    RENDER_TAG,
                    "🎵 Adding audio track $index: path=${track.path}, volume=${track.volume}, loop=${track.loop}"
                )

                val audioSequence = AudioSequenceBuilder(track.path, totalVideoDuration)
                    .setVolume(track.volume)
                    .setNormalization(needsNormalization)
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
        val composition = Composition.Builder(sequences).build()
        Log.d(RENDER_TAG, "Composition created successfully with ${sequences.size} sequences")

        return composition
    }
}