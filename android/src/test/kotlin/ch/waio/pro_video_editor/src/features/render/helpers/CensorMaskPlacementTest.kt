package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

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

    /** A 200 x 100 mask anchored on its center at [centerX], [centerY] (NDC). */
    private fun box(centerX: Float, centerY: Float, scale: Float = 1f) = CensorMaskPlacement.of(
        backgroundAnchor = floatArrayOf(centerX, centerY),
        overlayAnchor = floatArrayOf(0f, 0f),
        scale = floatArrayOf(scale, scale),
        maskWidth = 200,
        maskHeight = 100,
        frameWidth = frameWidth,
        frameHeight = frameHeight,
    )

    @Test
    fun aBoxOnTheFrameCoversIt() {
        assertTrue(box(-0.6f, 0.6f).coversFrame())
        // Mostly past the right edge, its left fifth still on the frame.
        assertTrue(box(1.1f, 0f).coversFrame())
    }

    @Test
    fun aBoxScaledToNothingCoversNothing() {
        // A scale animation from 0 starts here; the shader would divide by
        // the zero extent.
        assertFalse(box(-0.6f, 0.6f, scale = 0f).coversFrame())
    }

    @Test
    fun aBoxWhollyOffTheFrameCoversNothing() {
        // A slide in from an edge starts beyond it.
        assertFalse(box(1.3f, 0f).coversFrame())
        assertFalse(box(-1.3f, 0f).coversFrame())
        assertFalse(box(0f, 1.3f).coversFrame())
        assertFalse(box(0f, -1.3f).coversFrame())
    }

    @Test
    fun aWiggleTurnsTheQuadAroundItsCenter() {
        // The 200 x 100 box in the middle of the frame, turned a quarter
        // counter-clockwise, as Media3 turns an overlay with 90 degrees: its
        // right edge now points up, 100 pixels above the center.
        val placement = CensorMaskPlacement.of(
            backgroundAnchor = floatArrayOf(0f, 0f),
            overlayAnchor = floatArrayOf(0f, 0f),
            scale = floatArrayOf(1f, 1f),
            maskWidth = 200,
            maskHeight = 100,
            frameWidth = frameWidth,
            frameHeight = frameHeight,
            rotationDegrees = 90f,
        )

        assertQuad(1f to 0f, placement.quadCoordinateOf(0f, 0.4f))
        assertQuad(0f to 0f, placement.quadCoordinateOf(0f, 0f))
        // Its top edge points left, 50 pixels from the center.
        assertQuad(0f to 1f, placement.quadCoordinateOf(-0.1f, 0f))
    }

    @Test
    fun aTurnedBoxIsMeasuredByTheBoxAroundIt() {
        fun turned(degrees: Float) = CensorMaskPlacement.of(
            backgroundAnchor = floatArrayOf(1.15f, 0f),
            overlayAnchor = floatArrayOf(0f, 0f),
            scale = floatArrayOf(1f, 1f),
            maskWidth = 200,
            maskHeight = 100,
            frameWidth = frameWidth,
            frameHeight = frameHeight,
            rotationDegrees = degrees,
        )

        // Upright, its left 25 pixels are on the frame; turned upright on its
        // side, it is only 100 wide and lies wholly past the right edge.
        assertTrue(turned(0f).coversFrame())
        assertFalse(turned(90f).coversFrame())
    }
}
