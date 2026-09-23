package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.math.PI
import kotlin.math.hypot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

internal class SegmentPlacementMatrixTest {

    private companion object {
        const val CANVAS_W = 1080
        const val CANVAS_H = 1920

        /** A deliberately non-square box, so a shear would show up. */
        const val BOX_X = 200f
        const val BOX_Y = 500f
        const val BOX_W = 400f
        const val BOX_H = 200f
    }

    /**
     * Maps a draw-quad corner (`[-1, 1]` in x and y) through [matrix] and back
     * into canvas pixels with a top-left origin — the space the caller reasons
     * about.
     */
    private fun corner(matrix: FloatArray, qx: Float, qy: Float): Pair<Double, Double> {
        val ndcX = matrix[0] * qx + matrix[4] * qy + matrix[12]
        val ndcY = matrix[1] * qx + matrix[5] * qy + matrix[13]
        return Pair(
            (ndcX + 1.0) / 2.0 * CANVAS_W,
            (1.0 - ndcY) / 2.0 * CANVAS_H,
        )
    }

    private fun build(rotation: Double) = SegmentPlacementMatrix.build(
        x = BOX_X,
        y = BOX_Y,
        targetWidth = BOX_W,
        targetHeight = BOX_H,
        renderWidth = CANVAS_W,
        renderHeight = CANVAS_H,
        rotation = rotation,
    )

    private fun distance(a: Pair<Double, Double>, b: Pair<Double, Double>) =
        hypot(a.first - b.first, a.second - b.second)

    @Test
    fun build_unrotatedPlacesTheBoxExactly() {
        val matrix = build(0.0)

        val (leftX, topY) = corner(matrix, -1f, 1f)
        val (rightX, bottomY) = corner(matrix, 1f, -1f)
        assertEquals(BOX_X.toDouble(), leftX, 1e-3)
        assertEquals(BOX_Y.toDouble(), topY, 1e-3)
        assertEquals((BOX_X + BOX_W).toDouble(), rightX, 1e-3)
        assertEquals((BOX_Y + BOX_H).toDouble(), bottomY, 1e-3)
    }

    @Test
    fun build_unrotatedIsAPlainTranslateAndScale() {
        val matrix = build(0.0)

        // No off-diagonal terms at all: the historic matrix, bit for bit.
        assertEquals(0f, matrix[1])
        assertEquals(0f, matrix[4])
        assertEquals(BOX_W / CANVAS_W, matrix[0])
        assertEquals(BOX_H / CANVAS_H, matrix[5])
    }

    @Test
    fun build_rotationKeepsTheBoxCentre() {
        val centre = corner(build(0.0), 0f, 0f)

        for (angle in listOf(PI / 6, PI / 2, -PI / 4, 1.0, 3.0)) {
            val turned = corner(build(angle), 0f, 0f)
            assertTrue(
                distance(centre, turned) < 1e-3,
                "Rotation by $angle moved the box centre: $centre -> $turned",
            )
        }
    }

    @Test
    fun build_rotationDoesNotShearOnANonSquareCanvas() {
        // The whole point of turning in pixel space: on a 1080x1920 canvas the
        // NDC unit is 540px across and 960px down, so a turn applied in NDC
        // would stretch the edges. They must stay exactly 400 and 200.
        for (angle in listOf(PI / 6, PI / 2, -PI / 4, 1.0, 3.0)) {
            val matrix = build(angle)
            val topLeft = corner(matrix, -1f, 1f)
            val topRight = corner(matrix, 1f, 1f)
            val bottomLeft = corner(matrix, -1f, -1f)

            assertEquals(
                BOX_W.toDouble(), distance(topLeft, topRight), 1e-2,
                "Top edge changed length at $angle",
            )
            assertEquals(
                BOX_H.toDouble(), distance(topLeft, bottomLeft), 1e-2,
                "Left edge changed length at $angle",
            )
        }
    }

    @Test
    fun build_quarterTurnLaysTheTopEdgeDownTheRightHandSide() {
        val centreX = BOX_X + BOX_W / 2.0
        val centreY = BOX_Y + BOX_H / 2.0
        val matrix = build(PI / 2)

        // Clockwise, the top edge ends up running top-to-bottom along the box's
        // right-hand side: its two ends share an x of centre + H/2, and the
        // 400px between them is now vertical. A counter-clockwise turn would put
        // them on the left instead.
        val topLeft = corner(matrix, -1f, 1f)
        val topRight = corner(matrix, 1f, 1f)
        assertEquals(centreX + BOX_H / 2.0, topLeft.first, 1e-2)
        assertEquals(centreY - BOX_W / 2.0, topLeft.second, 1e-2)
        assertEquals(centreX + BOX_H / 2.0, topRight.first, 1e-2)
        assertEquals(centreY + BOX_W / 2.0, topRight.second, 1e-2)
    }

    @Test
    fun build_turnsClockwiseOnScreen() {
        val upright = build(0.0)
        val turned = build(PI / 6)

        // Which way a *corner* drifts depends on the box aspect, so read the
        // edge midpoints instead: under any clockwise turn the right edge goes
        // down and the top edge goes right. Counter-clockwise does the opposite,
        // so this pins the direction and not just the amount.
        val rightEdge = corner(turned, 1f, 0f)
        val uprightRightEdge = corner(upright, 1f, 0f)
        assertTrue(
            rightEdge.second > uprightRightEdge.second,
            "Right edge must move down, got $rightEdge vs $uprightRightEdge",
        )

        val topEdge = corner(turned, 0f, 1f)
        val uprightTopEdge = corner(upright, 0f, 1f)
        assertTrue(
            topEdge.first > uprightTopEdge.first,
            "Top edge must move right, got $topEdge vs $uprightTopEdge",
        )
    }

    @Test
    fun build_negativeRotationMirrorsThePositiveTurn() {
        val centreX = BOX_X + BOX_W / 2.0
        val centreY = BOX_Y + BOX_H / 2.0
        val clockwise = corner(build(PI / 6), 1f, 0f)
        val counterClockwise = corner(build(-PI / 6), 1f, 0f)

        // Same point, reflected across the box's horizontal centre line.
        assertEquals(clockwise.first, counterClockwise.first, 1e-2)
        assertEquals(clockwise.second - centreY, centreY - counterClockwise.second, 1e-2)
        assertTrue(clockwise.first > centreX)
    }

    @Test
    fun build_degenerateCanvasFallsBackToTheIdentityScale() {
        val matrix = SegmentPlacementMatrix.build(
            x = 0f,
            y = 0f,
            targetWidth = BOX_W,
            targetHeight = BOX_H,
            renderWidth = 0,
            renderHeight = 0,
            rotation = PI / 6,
        )

        assertEquals(1f, matrix[0])
        assertEquals(1f, matrix[5])
        assertEquals(0f, matrix[1])
        assertEquals(0f, matrix[4])
    }
}
