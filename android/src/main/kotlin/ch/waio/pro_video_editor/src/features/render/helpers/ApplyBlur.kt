import androidx.media3.common.Effect
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.GaussianBlur
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log

/**
 * Applies Gaussian blur effect to video.
 *
 * Uses GaussianBlur with sigma multiplied by 2.5 for visual consistency.
 * No effect if blur value is null or <= 0.
 *
 * @param videoEffects List to add blur effect to
 * @param blur Blur intensity (higher = more blur)
 */
@UnstableApi
fun applyBlur(videoEffects: MutableList<Effect>, blur: Double?) {
    if (blur == null || blur <= 0.0) return

    val actualSigma = blur.toFloat() * 2.5f
    Log.d(RENDER_TAG, "Applying Gaussian blur: intensity=$blur, sigma=$actualSigma")

    val blurEffect = GaussianBlur(blur.toFloat() * 2.5f)
    videoEffects += blurEffect
}