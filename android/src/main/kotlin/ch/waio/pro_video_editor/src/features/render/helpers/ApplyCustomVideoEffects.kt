import androidx.media3.common.Effect
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.effects.CustomVideoEffects
import ch.waio.pro_video_editor.src.features.render.helpers.CustomVideoEffectGlEffect
import ch.waio.pro_video_editor.src.features.render.models.CustomVideoEffectConfig
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log

/**
 * Adds the effects the app registered with [CustomVideoEffects] to an effect
 * chain, one stage each, in list order.
 *
 * Must be added right **before** the built-in video effects, so a custom
 * effect sees the clip as recorded.
 *
 * @param videoEffects List to add the effects to
 * @param effects The custom effects of the render, each with its time range
 * @param playbackSpeed The render-wide speed change that follows later in the
 *   chain, so the effects follow the output timeline
 * @throws IllegalArgumentException when nothing is registered under an
 *   effect's id, so the render fails before it starts instead of exporting
 *   without the effect
 */
@UnstableApi
fun applyCustomVideoEffects(
    videoEffects: MutableList<Effect>,
    effects: List<CustomVideoEffectConfig>,
    playbackSpeed: Float?,
) {
    if (effects.isEmpty()) return
    for (effect in effects) {
        require(CustomVideoEffects.isRegistered(effect.id)) {
            "No custom video effect is registered under \"${effect.id}\""
        }
    }
    Log.d(RENDER_TAG, "Applying ${effects.size} custom video effect(s): ${effects.joinToString { it.id }}")
    for (effect in effects) {
        videoEffects += CustomVideoEffectGlEffect(effect).withSpeedChange(playbackSpeed)
    }
}
