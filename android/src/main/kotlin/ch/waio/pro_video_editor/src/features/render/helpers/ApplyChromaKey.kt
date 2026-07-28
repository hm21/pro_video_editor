import androidx.media3.common.Effect
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.features.render.helpers.ChromaKeyEffect
import ch.waio.pro_video_editor.src.features.render.models.ChromaKeyConfig
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log

/**
 * Adds a chroma key ("green screen" removal) to a clip's effect chain.
 *
 * Must be added **before** rotation, flip, the color LUT and blur, so the key
 * sees the original decoded colors. Media3's LUT shader preserves alpha
 * (`gl_FragColor.a = inputColor.a`), so a color filter after the key is safe.
 *
 * @param videoEffects List to add the effect to
 * @param config The resolved key (clip ?: layer ?: global), or null for none
 * @param flattenTransparency Whether a key without a background should be
 *  filled with opaque black instead of left transparent. True on the
 *  single-track path — see below.
 */
@UnstableApi
fun applyChromaKey(
    videoEffects: MutableList<Effect>,
    config: ChromaKeyConfig?,
    flattenTransparency: Boolean = false,
) {
    if (config == null) return

    // H.264/HEVC carry no alpha channel, and the single-track path has no layer
    // underneath to blend into, so "transparent" has no meaning there. Left
    // alone the two platforms would disagree visibly: Apple's premultiplied
    // color cube writes rgb*0 and the area comes out black, while this shader
    // writes straight alpha and leaves the RGB untouched, so the screen would
    // simply stay green — "nothing happened". Substituting opaque black makes
    // both platforms produce the documented result.
    val effective = if (flattenTransparency && config.isTransparent) {
        config.copy(backgroundColor = OPAQUE_BLACK)
    } else {
        config
    }

    val background = when {
        effective.backgroundImageData != null -> "image"
        effective.backgroundColor != null -> "color"
        else -> "transparent"
    }
    Log.d(
        RENDER_TAG,
        "Applying chroma key: similarity=${effective.similarity} " +
            "smoothness=${effective.smoothness} spill=${effective.spill} " +
            "background=$background"
    )

    videoEffects += ChromaKeyEffect(effective)
}

private const val OPAQUE_BLACK = 0xFF000000.toInt()
