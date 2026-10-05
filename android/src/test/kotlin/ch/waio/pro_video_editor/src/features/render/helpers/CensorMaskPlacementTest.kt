package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pins [CensorMaskPlacement] to the spot Media3 draws the same overlay at, so
 * a censor layer hides exactly the area an image layer with the same settings
 * would cover.
 */
internal class CensorMaskPlacementTest {

    private val frameWidth = 1000
    private val frameHeight = 500

    /** The NDC of the top-left pixel corner [x], [y] (y down) of the frame. */
    private fun ndc(x: Float, y: Float) =
        2f * x / frameWidth - 1f to 1f - 2f * y / frameHeight

    private fun assertQuad(expected: Pair<Float, Float>, actual: Pair<Float, Float>) {
        assertEquals(expected.first, actual.first, 1e-5f)
        assertEquals(expected.second, actual.second, 1e-5f)
    }

    @Test
    fun aPositionedLayerCoversItsBox() {
        // A 200 x 100 layer at (100, 50), placed as prepareOverlay places it:
        // anchored on its center, at raster scale 1.
        val centerX = 100f + 100f
        val centerY = 50f + 50f
        val placement = CensorMaskPlacement.of(
            backgroundAnchor = floatArrayOf(
                centerX / frameWidth * 2f - 1f,
                1f - centerY / frameHeight * 2f,
            ),
            overlayAnchor = floatArrayOf(0f, 0f),
            scale = floatArrayOf(1f, 1f),
            maskWidth = 200,
            maskHeight = 100,
            frameWidth = frameWidth,
            frameHeight = frameHeight,
        )

        val (x0, y0) = ndc(100f, 50f)
        val (x1, y1) = ndc(300f, 150f)
        assertQuad(-1f to 1f, placement.quadCoordinateOf(x0, y0))
        assertQuad(1f to -1f, placement.quadCoordinateOf(x1, y1))
    }

    @Test
    fun pixelateBlocksStartAtTheBoxCorner() {
        // The 200 x 100 layer at (100, 50) of aPositionedLayerCoversItsBox.
        val placement = CensorMaskPlacement.of(
            backgroundAnchor = floatArrayOf(-0.6f, 0.6f),
            overlayAnchor = floatArrayOf(0f, 0f),
            scale = floatArrayOf(1f, 1f),
            maskWidth = 200,
            maskHeight = 100,
            frameWidth = frameWidth,
            frameHeight = frameHeight,
        )

        val corner = placement.topLeftPixel(frameWidth, frameHeight)
        assertEquals(100f, corner[0], 1e-3f)
        assertEquals(50f, corner[1], 1e-3f)
    }

    @Test
    fun aMaskRasteredSmallerIsScaledBackToItsBox() {
        // The same box, rastered at half size and compensated by the scale.
        val placement = CensorMaskPlacement.of(
            backgroundAnchor = floatArrayOf(-0.6f, 0.6f),
            overlayAnchor = floatArrayOf(0f, 0f),
            scale = floatArrayOf(2f, 2f),
            maskWidth = 100,
            maskHeight = 50,
            frameWidth = frameWidth,
            frameHeight = frameHeight,
        )

        val (x1, y1) = ndc(300f, 150f)
        assertQuad(1f to -1f, placement.quadCoordinateOf(x1, y1))
    }

    @Test
    fun aStretchedLayerCoversTheFrame() {
        // prepareOverlay anchors a stretched layer on both top-left corners.
        val placement = CensorMaskPlacement.of(
            backgroundAnchor = floatArrayOf(0f, 0f),
            overlayAnchor = floatArrayOf(0f, 0f),
            scale = floatArrayOf(1f, 1f),
            maskWidth = frameWidth,
            maskHeight = frameHeight,
            frameWidth = frameWidth,
            frameHeight = frameHeight,
        )

        assertQuad(-1f to 1f, placement.quadCoordinateOf(-1f, 1f))
        assertQuad(1f to -1f, placement.quadCoordinateOf(1f, -1f))
    }

    @Test
    fun anOffCanvasAnchorShiftsTheBox() {
        // AnimatedBitmapOverlay splits a center beyond the canvas into a
        // clamped background anchor and an overlay anchor.
        val placement = CensorMaskPlacement.of(
            backgroundAnchor = floatArrayOf(1f, 0f),
            overlayAnchor = floatArrayOf(-0.5f, 0f),
            scale = floatArrayOf(1f, 1f),
            maskWidth = 200,
            maskHeight = 100,
            frameWidth = frameWidth,
            frameHeight = frameHeight,
        )

        // Media3 puts the quad's center at bg - extent * oa = 1.1: a quarter
        // of the box's width past the right edge.
        assertQuad(0f to 0f, placement.quadCoordinateOf(1.1f, 0f))
    }
}
