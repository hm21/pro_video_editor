package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.ShapeMaskShape
import ch.waio.pro_video_editor.src.features.render.models.ShapeMaskState
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pins the outlines and the softness of a shape mask to the `LayerMask` of
 * pro_image_editor, which draws the editor preview.
 */
internal class ShapeMaskGeometryTest {

    private val tol = 1e-6

    private fun state(
        shape: ShapeMaskShape,
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        width: Double = 0.5,
        height: Double = 0.5,
        feather: Double = 0.0,
        cornerRadius: Double = 0.0,
    ) = ShapeMaskState(
        shape, centerX, centerY, width, height, 0.0, feather, cornerRadius,
        invert = false, mirrored = false,
    )

    @Test
    fun `the box is centred on the centre and sized in fractions of the image`() {
        val rect = ShapeMaskGeometry.shapeRect(
            state(ShapeMaskShape.ELLIPSE, centerX = 0.5, centerY = 0.25, width = 0.5, height = 0.25),
            200, 400,
        )

        assertEquals(MaskRect(50.0, 50.0, 150.0, 150.0), rect)
    }

    @Test
    fun `a rectangle rounds its corners by half its shorter side at most`() {
        val outline = ShapeMaskGeometry.outline(
            state(ShapeMaskShape.RECTANGLE, width = 0.5, height = 0.25, cornerRadius = 0.5),
            200, 400,
        ) as MaskOutline.RoundRect

        assertEquals(25.0, outline.radius, tol)
    }

    @Test
    fun `a star spans its box from the top point to the outer points`() {
        val star = ShapeMaskGeometry.UNIT_STAR

        assertEquals(10, star.size)
        assertEquals(0.5, star[0].first, tol)
        assertEquals(0.0, star[0].second, tol)
        assertEquals(0.0, star.minOf { it.first }, tol)
        assertEquals(1.0, star.maxOf { it.first }, tol)
        assertEquals(0.0, star.minOf { it.second }, tol)
        assertEquals(1.0, star.maxOf { it.second }, tol)
    }

    @Test
    fun `a polygon fills its box`() {
        val ops = ShapeMaskGeometry.polygon(
            ShapeMaskGeometry.UNIT_TRIANGLE, MaskRect(10.0, 20.0, 110.0, 70.0)
        )

        assertEquals(
            listOf(
                MaskPathOp.MoveTo(60.0, 20.0),
                MaskPathOp.LineTo(110.0, 70.0),
                MaskPathOp.LineTo(10.0, 70.0),
                MaskPathOp.Close,
            ),
            ops,
        )
    }

    @Test
    fun `a heart starts at its tip at the bottom middle of its box`() {
        val ops = ShapeMaskGeometry.heart(MaskRect(0.0, 0.0, 100.0, 200.0))

        assertEquals(MaskPathOp.MoveTo(50.0, 200.0), ops.first())
        assertEquals(MaskPathOp.Close, ops.last())
        // The dip between the two lobes, a tenth of the way down.
        val dip = ops[4] as MaskPathOp.CubicTo
        assertEquals(50.0, dip.x, tol)
        assertEquals(22.78, dip.y, tol)
    }

    @Test
    fun `a speech bubble keeps round corners of a fifth of its body`() {
        val ops = ShapeMaskGeometry.speechBubble(MaskRect(0.0, 0.0, 200.0, 100.0))
        // The body is 80 high; its corners a fifth of that.
        val r = 16.0

        assertEquals(MaskPathOp.MoveTo(r, 0.0), ops.first())
        assertEquals(
            MaskPathOp.ArcTo(MaskRect(200.0 - 2 * r, 0.0, 200.0, 2 * r), -90.0, 90.0),
            ops[2],
        )
        // The tail reaches the bottom of the box.
        assertTrue(ops.contains(MaskPathOp.LineTo(24.0, 100.0)))
    }

    @Test
    fun `the softness is a Gaussian of a 2,56th of the feather on the shorter side`() {
        val featherPx = ShapeMaskGeometry.featherPx(
            state(ShapeMaskShape.ELLIPSE, feather = 0.1), 1080, 1920
        )

        assertEquals(108.0, featherPx, tol)
        assertEquals(108.0 / 2.56, ShapeMaskGeometry.blurSigma(featherPx), tol)
    }

    @Test
    fun `the blur radius undoes Skia's radius to sigma conversion`() {
        val sigma = 20.0

        val radius = ShapeMaskGeometry.blurRadius(sigma)

        assertEquals(sigma, radius * 0.57735 + 0.5, tol)
        assertEquals(0.0, ShapeMaskGeometry.blurRadius(0.4), tol)
    }

    @Test
    fun `a linear edge reaches the farthest corner`() {
        val reach = ShapeMaskGeometry.linearReach(
            state(ShapeMaskShape.LINEAR, centerX = 0.0, centerY = 0.0), 300, 400
        )

        assertEquals(sqrt(300.0 * 300.0 + 400.0 * 400.0), reach, tol)
    }

    @Test
    fun `masking scales a straight alpha and keeps the colors`() {
        // Two rows of one pixel, the matte's rows padded to 4 bytes.
        val pixels = byteArrayOf(10, 20, 30, 200.toByte(), 1, 2, 3, 255.toByte())
        val matte = byteArrayOf(128.toByte(), 0, 0, 0, 255.toByte(), 0, 0, 0)

        maskStraightAlpha(pixels, matte, width = 1, height = 2, matteRowBytes = 4)

        assertEquals(listOf<Byte>(10, 20, 30), pixels.slice(0..2))
        assertEquals((200 * 128 + 127) / 255, pixels[3].toInt() and 0xFF)
        assertEquals(listOf<Byte>(1, 2, 3, 255.toByte()), pixels.slice(4..7))
    }
}
