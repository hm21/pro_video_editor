import androidx.media3.common.Effect
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.ScaleAndRotateTransformation
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log

/**
 * Applies video rotation transformation.
 *
 * Rotates the video by the specified degrees (clockwise).
 * No effect if rotation is a multiple of 360°.
 *
 * @param videoEffects List to add rotation effect to
 * @param rotationDegrees Rotation in degrees (0-360)
 */
@UnstableApi
fun applyRotation(videoEffects: MutableList<Effect>, rotationDegrees: Float) {
    if (rotationDegrees % 360f == 0f) return

    Log.d(RENDER_TAG, "Applying rotation: ${rotationDegrees}°")
    videoEffects += ScaleAndRotateTransformation.Builder()
        .setRotationDegrees(rotationDegrees)
        .build()
}
