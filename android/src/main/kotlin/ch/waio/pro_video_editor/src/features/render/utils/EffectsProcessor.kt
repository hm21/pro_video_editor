package ch.waio.pro_video_editor.src.features.render

import androidx.media3.common.Effect
import androidx.media3.common.audio.AudioProcessor
import applyBlur
import applyColorMatrix
import applyFlip
import applyMaxFrameRate
import applyPlaybackSpeed
import applyRotation
import applyCustomVideoEffects
import applyVideoEffects
import ch.waio.pro_video_editor.src.features.render.models.RenderConfig

/**
 * Processes and applies video/audio effects based on render configuration.
 *
 * This class encapsulates the logic for building effect pipelines from a RenderConfig,
 * providing a cleaner API compared to multiple individual apply function calls.
 * All effects are applied in a consistent order for predictable results.
 */
class EffectsProcessor {

    /**
     * Data class holding the processed video and audio effects.
     */
    data class ProcessedEffects(
        val videoEffects: List<Effect>,
        val audioEffects: List<AudioProcessor>
    )

    /**
     * Processes the render configuration and builds effect pipelines.
     *
     * Effects are applied in the following order:
     * 1. Playback Speed - Adjusts video/audio speed
     * 2. Frame Rate - Caps the output frame rate (drops surplus frames)
     * 3. Rotation - Corrects video orientation
     * 4. Flip - Horizontal/vertical mirroring
     * 5. Custom Video Effects - Effects the app registered itself
     * 6. Video Effects - Glitch, VHS, pixelate and other pixel effects
     * 7. Color Matrix - Applies color transformations (filters, adjustments)
     * 8. Blur - Applies blur effect
     *
     * Scale is applied later by VideoSequenceBuilder, after overlay and crop.
     *
     * @param config The render configuration containing effect parameters
     * @return ProcessedEffects containing lists of video and audio effects
     */
    fun process(config: RenderConfig): ProcessedEffects {
        val videoEffects = mutableListOf<Effect>()
        val audioEffects = mutableListOf<AudioProcessor>()

        // Calculate rotation degrees (4 - turns ensures correct direction)
        val rotationDegrees = (4 - (config.rotateTurns ?: 0)) * 90f

        // Speed first, so every effect after it times itself on the output
        // timeline. The frame rate cap follows it, so it applies to that
        // timeline and no later effect draws a frame it drops.
        applyPlaybackSpeed(videoEffects, audioEffects, config.playbackSpeed)
        applyMaxFrameRate(videoEffects, config.maxFrameRate)
        applyRotation(videoEffects, rotationDegrees)
        applyFlip(videoEffects, config.flipX, config.flipY)
        // Scale is NOT applied here — it is applied by VideoSequenceBuilder
        // AFTER overlay and crop to match the iOS/macOS pipeline order.
        applyCustomVideoEffects(videoEffects, config.customEffects)
        applyVideoEffects(videoEffects, config.effects)
        applyColorMatrix(videoEffects, config.colorFilters)
        applyBlur(videoEffects, config.blur)

        return ProcessedEffects(videoEffects, audioEffects)
    }
}
