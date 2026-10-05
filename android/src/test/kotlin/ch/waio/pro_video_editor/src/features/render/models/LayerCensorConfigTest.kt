package ch.waio.pro_video_editor.src.features.render.models

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame

internal class LayerCensorConfigTest {

    @Test
    fun aLayerWithoutCensorIsDrawnAsAnImage() {
        assertNull(LayerCensorConfig.fromMap(null))
    }

    @Test
    fun parsesTypeAndStrength() {
        assertEquals(
            LayerCensorConfig(LayerCensorConfig.Type.PIXELATE, 18.0),
            LayerCensorConfig.fromMap(mapOf("type" to "pixelate", "strength" to 18)),
        )
        assertEquals(
            LayerCensorConfig(LayerCensorConfig.Type.BLUR, 7.5),
            LayerCensorConfig.fromMap(mapOf("type" to "blur", "strength" to 7.5)),
        )
    }

    @Test
    fun anIncompleteCensorStillHidesTheArea() {
        // Showing the mask image instead would draw a plain shape over the
        // very thing the layer was meant to hide.
        assertEquals(
            LayerCensorConfig(LayerCensorConfig.Type.BLUR, 24.0),
            LayerCensorConfig.fromMap(mapOf("type" to "swirl", "strength" to -3)),
        )
    }

    @Test
    fun aBlockIsWholePixelsAndNeverSmallerThanTwo() {
        assertEquals(5, LayerCensorConfig(LayerCensorConfig.Type.PIXELATE, 4.6).blockSize)
        assertEquals(2, LayerCensorConfig(LayerCensorConfig.Type.PIXELATE, 0.4).blockSize)
    }

    @Test
    fun scalesWithTheFrameTheLayerIsLaidOutIn() {
        val censor = LayerCensorConfig(LayerCensorConfig.Type.BLUR, 10.0)

        assertEquals(15.0, censor.scaled(1.5).strength)
        assertSame(censor, censor.scaled(1.0))
    }
}
