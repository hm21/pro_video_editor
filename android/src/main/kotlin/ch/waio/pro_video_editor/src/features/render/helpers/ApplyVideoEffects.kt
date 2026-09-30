import androidx.media3.common.Effect
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.features.render.helpers.VideoEffectGlEffect
import ch.waio.pro_video_editor.src.features.render.models.VideoEffectConfig
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log

/**
 * Adds the video effects (glitch, VHS, pixelate, …) to an effect chain.
 *
 * Must be added right **before** the color LUT, so a color filter colors the
 * distorted picture — the order the Flutter preview and Apple's compositor use.
 *
 * @param videoEffects List to add the effect to
 * @param effects The effects of the render, each with its time range
 * @param playbackSpeed The render-wide speed change that follows later in the
 *   chain, so the effects follow the output timeline
 */
@UnstableApi
fun applyVideoEffects(
    videoEffects: MutableList<Effect>,
    effects: List<VideoEffectConfig>,
    playbackSpeed: Float?,
) {
    if (effects.isEmpty()) return
    Log.d(RENDER_TAG, "Applying ${effects.size} video effect(s)")
    videoEffects += VideoEffectGlEffect(effects).withSpeedChange(playbackSpeed)
}
