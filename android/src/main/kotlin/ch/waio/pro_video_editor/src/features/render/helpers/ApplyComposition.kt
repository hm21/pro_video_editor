package ch.waio.pro_video_editor.src.features.render.helpers

import android.content.Context
import androidx.media3.common.Effect
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import ch.waio.pro_video_editor.src.features.render.models.RenderConfig
import java.io.File

/**
 * Result of building a composition: the composition itself plus a list of
 * temporary files that were created during the build (e.g. pre-rendered
 * audio WAVs). The caller MUST delete these temporary files after the
 * Transformer export finishes (success or failure).
 */
data class CompositionResult(
    val composition: Composition,
    val temporaryFiles: List<File>
)

/**
 * Creates a Media3 Composition from render configuration.
 *
 * This is a simplified wrapper function that delegates the actual work
 * to CompositionBuilder. The builder pattern provides better separation
 * of concerns and cleaner code organization.
 *
 * @param context Android context
 * @param config The render configuration containing all composition parameters
 * @param videoEffects List of video effects to apply (from EffectsProcessor)
 * @param audioEffects List of audio effects to apply (from EffectsProcessor)
 * @return [CompositionResult] with the composition and any temporary files
 *   created during the build, or null if no video clips were provided.
 */
@UnstableApi
fun applyComposition(
    context: Context,
    config: RenderConfig,
    videoEffects: List<Effect>,
    audioEffects: List<AudioProcessor>
): CompositionResult? {
    val builder = CompositionBuilder(context, config)
        .setVideoEffects(videoEffects)
        .setAudioEffects(audioEffects)
    val composition = builder.build() ?: return null
    return CompositionResult(composition, builder.temporaryFiles.toList())
}