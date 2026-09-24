package ch.waio.pro_video_editor.src.features.render.helpers

import androidx.media3.transformer.Composition
import kotlin.test.Test
import kotlin.test.assertEquals

internal class HdrToneMappingTest {

    @Test
    fun openGlToneMapSupported_keepsTheOpenGlToneMapper() {
        assertEquals(
            Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL,
            HdrToneMapping.sdrHdrMode(openGlToneMapSupported = true)
        )
    }

    @Test
    fun openGlToneMapUnsupported_readsHdrAsSdr() {
        // A driver without GL_EXT_YUV_target: the OpenGL tone-mapper fails
        // every frame, so the clip is read as SDR rather than not exported.
        assertEquals(
            Composition.HDR_MODE_EXPERIMENTAL_FORCE_INTERPRET_HDR_AS_SDR,
            HdrToneMapping.sdrHdrMode(openGlToneMapSupported = false)
        )
    }
}
