import androidx.media3.common.Effect
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.FrameDropEffect
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log

/**
 * Caps the output frame rate at [maxFrameRate] frames per second.
 *
 * Uses Media3's [FrameDropEffect], which only ever drops frames to approximate
 * the target frame rate — it never duplicates them. A source that already runs
 * at or below [maxFrameRate] is therefore left untouched, so this acts as an
 * upper limit rather than a fixed target.
 *
 * No effect when [maxFrameRate] is null or not positive.
 *
 * @param videoEffects List to add the frame-drop effect to
 * @param maxFrameRate Maximum output frame rate in fps (null = keep source fps)
 */
@UnstableApi
fun applyMaxFrameRate(videoEffects: MutableList<Effect>, maxFrameRate: Int?) {
    if (maxFrameRate == null || maxFrameRate <= 0) return

    Log.d(RENDER_TAG, "Capping output frame rate at $maxFrameRate fps")
    videoEffects += FrameDropEffect.createDefaultFrameDropEffect(maxFrameRate.toFloat())
}
