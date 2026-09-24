package ch.waio.pro_video_editor.src.features.render.helpers

import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition

/**
 * Decides how an HDR source becomes SDR on this device.
 *
 * Media3's OpenGL tone-mapper samples the decoder's raw YUV through the
 * `GL_EXT_YUV_target` extension. A GL driver without it fails the shader
 * compile, and with it every frame, as
 * `ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED`. Many drivers below Android 12
 * lack it, and below API 31 Media3 has no other route to SDR: even
 * `HDR_MODE_KEEP_HDR` falls back to the OpenGL tone-mapper there. On such a
 * device the HDR clip is read as SDR instead. Its colors come out flatter
 * than the source, but the export finishes.
 */
@UnstableApi
object HdrToneMapping {

    /** Whether Media3's OpenGL tone-mapper can run here; probed once per process. */
    val isOpenGlToneMapSupported: Boolean by lazy {
        GlUtil.isYuvTargetExtensionSupported()
    }

    /** The `Composition` HDR mode that turns an HDR source into SDR output. */
    fun sdrHdrMode(openGlToneMapSupported: Boolean = isOpenGlToneMapSupported): Int =
        if (openGlToneMapSupported) {
            Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
        } else {
            Composition.HDR_MODE_EXPERIMENTAL_FORCE_INTERPRET_HDR_AS_SDR
        }
}
