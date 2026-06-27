package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import androidx.media3.common.Effect
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.AlphaScale
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log

/**
 * Applies opacity to a video segment.
 *
 * @param videoEffects List to add opacity effect to
 * @param opacity Transparency factor (0.0 to 1.0)
 */
@UnstableApi
fun applyOpacity(
    videoEffects: MutableList<Effect>,
    opacity: Float?
) {
    if (opacity == null || opacity >= 1.0f) return

    Log.d(RENDER_TAG, "Applying opacity: $opacity")
    videoEffects += AlphaScale(opacity)
}
