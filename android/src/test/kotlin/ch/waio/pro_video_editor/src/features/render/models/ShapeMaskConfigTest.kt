package ch.waio.pro_video_editor.src.features.render.models

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Pins how a shape mask reads off the channel and how its keyframes change it,
 * as `layerMaskKeyframeAt` in pro_image_editor does for the editor preview.
 */
internal class ShapeMaskConfigTest {

    private val tol = 1e-9

    private val wire = mapOf(
        "shape" to "speechBubble",
        "x" to 0.25,
        "y" to 0.75,
        "width" to 0.4,
        "height" to 0.2,
        "rotation" to 0.5,
        "feather" to 0.1,
        "cornerRadius" to 0.3,
        "invert" to true,
        "mirrored" to true,
        "keyframes" to listOf(
            mapOf(
                "timeUs" to 3_000_000L, "x" to 0.8, "y" to 0.6, "width" to 1.0,
                "height" to 0.6, "rotation" to 2.0, "feather" to 0.4, "curve" to "linear",
            ),
            mapOf(
                "timeUs" to 1_000_000L, "x" to 0.2, "y" to 0.4, "width" to 0.2,
                "height" to 0.2, "rotation" to 0.0, "feather" to 0.0, "curve" to "easeIn",
            ),
        ),
    )

    @Test
    fun `reads every field and sorts the keyframes`() {
        val mask = ShapeMaskConfig.from(wire)!!

        assertEquals(ShapeMaskShape.SPEECH_BUBBLE, mask.shape)
        assertEquals(0.25, mask.centerX, tol)
        assertEquals(0.75, mask.centerY, tol)
        assertEquals(0.4, mask.width, tol)
        assertEquals(0.2, mask.height, tol)
        assertEquals(0.3, mask.cornerRadius, tol)
        assertTrue(mask.invert)
        assertTrue(mask.mirrored)
        assertEquals(listOf(1_000_000L, 3_000_000L), mask.keyframes.map { it.timeUs })
        assertEquals("easeIn", mask.keyframes.first().curve)
    }

    @Test
    fun `is null without a map and falls back to an ellipse for an unknown shape`() {
        assertNull(ShapeMaskConfig.from(null))
        val mask = ShapeMaskConfig.from(
            mapOf(
                "shape" to "spiral", "width" to -1, "height" to -0.5, "feather" to -1,
                "cornerRadius" to 3,
                "keyframes" to listOf(mapOf("timeUs" to 0, "width" to -2, "height" to -1)),
            )
        )!!
        assertEquals(ShapeMaskShape.ELLIPSE, mask.shape)
        assertEquals(0.0, mask.width, tol)
        assertEquals(0.0, mask.height, tol)
        assertEquals(0.0, mask.feather, tol)
        assertEquals(1.0, mask.cornerRadius, tol)
        // Held before and after the only keyframe, its size is kept at 0 too.
        assertEquals(0.0, mask.stateAt(0L).width, tol)
        assertEquals(0.0, mask.stateAt(0L).height, tol)
    }

    @Test
    fun `shows its own values without keyframes`() {
        val mask = ShapeMaskConfig.from(wire)!!.copy(keyframes = emptyList())

        val state = mask.stateAt(5_000_000L)

        assertEquals(0.25, state.centerX, tol)
        assertEquals(0.1, state.feather, tol)
        assertTrue(state.invert)
        assertTrue(state.mirrored)
    }

    @Test
    fun `holds the first keyframe before it and the last after it`() {
        val mask = ShapeMaskConfig.from(wire)!!

        assertEquals(0.2, mask.stateAt(0L).centerX, tol)
        val after = mask.stateAt(9_000_000L)
        assertEquals(0.8, after.centerX, tol)
        assertEquals(0.4, after.feather, tol)
        assertEquals(0.3, after.cornerRadius, tol)
    }

    @Test
    fun `eases along the earlier keyframe's curve`() {
        val mask = ShapeMaskConfig.from(wire)!!

        // Halfway in time, an ease in has come a quarter of the way.
        val state = mask.stateAt(2_000_000L)

        assertEquals(0.2 + 0.6 * 0.25, state.centerX, tol)
        assertEquals(0.2 + 0.8 * 0.25, state.width, tol)
        assertEquals(0.5, state.rotation, tol)
        assertEquals(0.1, state.feather, tol)
    }

    @Test
    fun `keeps the size and the softness at 0 or more when a curve overshoots`() {
        val mask = ShapeMaskConfig(
            shape = ShapeMaskShape.ELLIPSE,
            keyframes = listOf(
                ShapeMaskKeyframeConfig(0L, width = 1.0, height = 1.0, feather = 0.3, curve = "elasticOut"),
                ShapeMaskKeyframeConfig(1_000_000L, width = 0.0, height = 0.0, feather = 0.0),
            ),
        )

        for (us in 0L..1_000_000L step 20_000L) {
            val state = mask.stateAt(us)
            assertTrue(state.width >= 0.0, "width at $us")
            assertTrue(state.height >= 0.0, "height at $us")
            assertTrue(state.feather >= 0.0, "feather at $us")
        }
    }

    @Test
    fun `a layer reads its shape mask off the channel map`() {
        val layer = LayerConfig.fromMap(
            mapOf(
                "clips" to listOf(mapOf("inputPath" to "clip.mp4")),
                "shapeMask" to wire,
            )
        )!!

        assertEquals(ShapeMaskShape.SPEECH_BUBBLE, layer.shapeMask!!.shape)
        assertNull(LayerConfig.fromMap(mapOf("clips" to listOf(mapOf("inputPath" to "c.mp4"))))!!.shapeMask)
    }
}
