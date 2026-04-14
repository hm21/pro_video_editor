import androidx.media3.common.Effect
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.SpeedChangeEffect
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log

/**
 * Applies playback speed modification to both video and audio.
 *
 * Uses SpeedChangeEffect for video and SonicAudioProcessor for audio
 * to maintain synchronization. Values > 1.0 speed up, < 1.0 slow down.
 *
 * @param videoEffects List to add video speed effect to
 * @param audioEffects List to add audio speed processor to
 * @param playbackSpeed Speed multiplier (0.5 = half speed, 2.0 = double speed)
 */
@UnstableApi
fun applyPlaybackSpeed(
    videoEffects: MutableList<Effect>,
    audioEffects: MutableList<AudioProcessor>,
    playbackSpeed: Float?
) {
    if (playbackSpeed == null || playbackSpeed <= 0f) return

    Log.d(RENDER_TAG, "Applying playback speed: $playbackSpeed×")
    videoEffects += SpeedChangeEffect(playbackSpeed)

    val audio = SonicAudioProcessor()
    audio.setSpeed(playbackSpeed)
    audioEffects += audio
}