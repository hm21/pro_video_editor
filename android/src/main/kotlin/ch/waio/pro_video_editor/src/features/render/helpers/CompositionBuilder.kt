package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.util.Log
import androidx.media3.common.Effect
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItemSequence
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
     * Builds the complete composition with video and optional custom audio.
     * 
     * @return Composition ready for Media3 Transformer, or null if no video clips
     */
    fun build(): Composition? {
        if (config.videoClips.isEmpty()) {
            return null
        }

        Log.d(RENDER_TAG, "Creating composition with ${config.videoClips.size} video clips")
        Log.d(RENDER_TAG, "Audio enabled: ${config.enableAudio}")

        val rotationDegrees = (4 - (config.rotateTurns ?: 0)) * 90f

        // Check if custom audio is provided
        val hasCustomAudio = config.customAudioPath != null && config.customAudioPath.isNotEmpty()

        // Build video sequence
        val videoBuilder = VideoSequenceBuilder(config.videoClips)
            .setVideoEffects(videoEffects)
            .setAudioEffects(audioEffects)
            .setRotation(rotationDegrees)
            .setFlip(config.flipX, config.flipY)
            .setCrop(config.cropWidth, config.cropHeight, config.cropX, config.cropY)
            .setImageLayer(config.imageBytes, config.scaleX, config.scaleY)
            .setEnableAudio(config.enableAudio)
            .setOriginalAudioVolume(config.originalAudioVolume)
            .setGlobalTrim(config.startUs, config.endUs)
            .setHasCustomAudio(hasCustomAudio)
        
        // Detect if audio normalization is needed (check both video and custom audio)
        val needsNormalization = videoBuilder.detectAudioNormalizationNeeded() || hasCustomAudio
        videoBuilder.setAudioNormalization(needsNormalization)

        // Video keeps its audio - Media3 will mix it natively with custom audio sequence
        // No need to remove original audio anymore!
        videoBuilder.setForceRemoveAudio(false)

        // Build video sequence (with audio intact)
        val videoSequence = videoBuilder.build()
        
        // Prepare sequences list
        val sequences = mutableListOf<EditedMediaItemSequence>()
        sequences.add(videoSequence)
        Log.d(RENDER_TAG, "Created video EditedMediaItemSequence with ${config.videoClips.size} items")

        // Add custom audio as separate sequence - Media3 will mix both tracks natively
        if (hasCustomAudio) {
            val totalVideoDuration = videoBuilder.calculateTotalDuration()
            
            val hasOriginalAudio = config.originalAudioVolume != null && config.originalAudioVolume > 0.0f
            
            if (hasOriginalAudio) {
                Log.d(
                    RENDER_TAG,
                    "🎵 Native audio mixing: Video audio (${config.originalAudioVolume}x) + Custom audio (${config.customAudioVolume}x)"
                )
                Log.d(RENDER_TAG, "Media3 will mix both audio tracks natively via parallel sequences")
            } else {
                Log.d(RENDER_TAG, "Only custom audio (no video audio)")
            }
            
            // Add custom audio sequence - Media3 will automatically mix it with video audio
            val audioSequence = AudioSequenceBuilder(config.customAudioPath!!, totalVideoDuration)
                .setVolume(config.customAudioVolume ?: 1.0f)
                .setNormalization(needsNormalization)
                .build()

            if (audioSequence != null) {
                sequences.add(audioSequence)
                Log.d(RENDER_TAG, "Custom audio sequence added (will be mixed natively by Media3)")
            }
        }

        // Build final composition
        val composition = Composition.Builder(sequences).build()
        Log.d(RENDER_TAG, "Composition created successfully with ${sequences.size} sequences")

        return composition
    }
}