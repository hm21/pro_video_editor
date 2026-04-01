package ch.waio.pro_video_editor.src.features.render

import androidx.media3.common.Effect
import androidx.media3.common.audio.AudioProcessor
import applyBlur
import applyColorMatrix
import applyFlip
import applyPlaybackSpeed
import applyRotation
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
     * 1. Rotation - Corrects video orientation
     * 2. Flip - Horizontal/vertical mirroring
     * 3. Scale - Resizes video dimensions
     * 4. Color Matrix - Applies color transformations (filters, adjustments)
     * 5. Blur - Applies blur effect
     * 6. Playback Speed - Adjusts video/audio speed
     *
     * @param config The render configuration containing effect parameters
     * @return ProcessedEffects containing lists of video and audio effects
     */
    fun process(config: RenderConfig): ProcessedEffects {
        val videoEffects = mutableListOf<Effect>()
        val audioEffects = mutableListOf<AudioProcessor>()

        // Calculate rotation degrees (4 - turns ensures correct direction)
        val rotationDegrees = (4 - (config.rotateTurns ?: 0)) * 90f

        // Apply effects in order
        applyRotation(videoEffects, rotationDegrees)
        applyFlip(videoEffects, config.flipX, config.flipY)
        // Scale is NOT applied here — it is applied by VideoSequenceBuilder
        // AFTER overlay and crop to match the iOS/macOS pipeline order.
        applyColorMatrix(videoEffects, config.colorFilters)
        applyBlur(videoEffects, config.blur)
        applyPlaybackSpeed(videoEffects, audioEffects, config.playbackSpeed)

        return ProcessedEffects(videoEffects, audioEffects)
    }
}
