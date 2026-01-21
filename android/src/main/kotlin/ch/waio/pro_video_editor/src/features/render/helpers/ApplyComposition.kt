package ch.waio.pro_video_editor.src.features.render.helpers

import android.content.Context
import androidx.media3.common.Effect
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import ch.waio.pro_video_editor.src.features.render.models.RenderConfig

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
 * @return Composition ready for transformer, or null if no video clips provided
 */
@UnstableApi
fun applyComposition(
    context: Context,
    config: RenderConfig,
    videoEffects: List<Effect>,
    audioEffects: List<AudioProcessor>
): Composition? {
    return CompositionBuilder(context, config)
        .setVideoEffects(videoEffects)
        .setAudioEffects(audioEffects)
        .build()
}