package ch.waio.pro_video_editor.src.features.render.helpers

import android.graphics.Matrix
import ch.waio.pro_video_editor.src.features.render.models.KeyframeConfig
import kotlin.math.PI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Pins how a segment's keyframes move its frames: the mix at a source
 * timestamp, the mirrored keyframes of a reversed copy, the Media3 matrix and
 * the CPU warp the overlap blends use, which must move a frame alike.
 */
internal class SegmentMotionTest {

    private val tol = 1e-6

    private fun keyframe(
        timeUs: Long,
        dx: Double = 0.0,
        dy: Double = 0.0,
        scale: Double = 1.0,
        rotation: Double = 0.0,
        curve: String = "linear",
    ) = KeyframeConfig(timeUs, dx, dy, scale, rotation, curve = curve)

    @Test
    fun `no keyframes move nothing`() {
        assertNull(segmentMotionAt(emptyList(), 0L))
    }

    @Test
    fun `mixes the motion between two keyframes by source time`() {
        val keyframes = listOf(
            keyframe(1_000_000L),
            keyframe(3_000_000L, dx = 0.2, dy = -0.4, scale = 3.0, rotation = PI),
        )

        val motion = segmentMotionAt(keyframes, 2_000_000L)!!

        assertEquals(0.1, motion.dx, tol)
        assertEquals(-0.2, motion.dy, tol)
        assertEquals(2.0, motion.scale, tol)
        assertEquals(PI / 2, motion.rotation, tol)
        assertEquals(FrameMotion(0.0, 0.0, 1.0, 0.0), segmentMotionAt(keyframes, 0L))
    }

    @Test
    fun `a reversed copy shows every frame with the motion of its source time`() {
        val keyframes = listOf(
            keyframe(500_000L, dx = -0.1, curve = "easeIn"),
            keyframe(1_500_000L, scale = 2.0, curve = "bounceOut"),
            keyframe(2_000_000L, dx = 0.3, rotation = 1.0),
        )
        val lastPtsUs = 2_400_000L

        val reversed = reversedSegmentKeyframes(keyframes, lastPtsUs)

        assertEquals(listOf(400_000L, 900_000L, 1_900_000L), reversed.map { it.timeUs })
        assertEquals(listOf("bounceIn", "easeOut", "linear"), reversed.map { it.curve })
        for (sourceUs in 0L..lastPtsUs step 50_000L) {
            val forward = segmentMotionAt(keyframes, sourceUs)!!
            val backward = segmentMotionAt(reversed, lastPtsUs - sourceUs)!!
            assertEquals(forward.dx, backward.dx, 1e-9)
            assertEquals(forward.scale, backward.scale, 1e-9)
            assertEquals(forward.rotation, backward.rotation, 1e-9)
        }
    }

    @Test
    fun `symmetric curves are their own mirror`() {
        for (curve in listOf("linear", "easeInOut", "easeInOutCubic", "bounceInOut")) {
            assertEquals(curve, mirroredCurve(curve))
        }
    }

    @Test
    fun `the Media3 matrix shifts by twice the fraction in device coordinates`() {
        val values = FloatArray(9)
        motionNdcValues(FrameMotion(dx = 0.25, dy = 0.1, scale = 1.0, rotation = 0.0), 0.5, values)

        assertEquals(1f, values[Matrix.MSCALE_X], 1e-6f)
        assertEquals(0.5f, values[Matrix.MTRANS_X], 1e-6f)
        // Device y points up, the motion's down.
        assertEquals(-0.2f, values[Matrix.MTRANS_Y], 1e-6f)
    }

    @Test
    fun `the Media3 matrix turns clockwise on screen`() {
        val values = FloatArray(9)
        val aspect = 9.0 / 16.0
        motionNdcValues(FrameMotion(0.0, 0.0, 1.0, PI / 2), aspect, values)

        // A point right of the center, at a quarter of the width, ends below
        // it after a clockwise quarter turn: a quarter width further down.
        val x = 0.5
        val y = 0.0
        val turnedX = values[Matrix.MSCALE_X].toDouble() * x + values[Matrix.MSKEW_X].toDouble() * y
        val turnedY = values[Matrix.MSKEW_Y].toDouble() * x + values[Matrix.MSCALE_Y].toDouble() * y
        assertEquals(0.0, turnedX, 1e-6)
        // A quarter of the width is `aspect` quarters of the height: -0.5 *
        // aspect in device units, whose y points up.
        assertEquals(-0.5 * aspect, turnedY, 1e-6)
    }

    @Test
    fun `the warp zooms around the center and fills uncovered pixels with black`() {
        val width = 8
        val height = 8
        val src = gradientFrame(width, height)
        val out = ByteArray(src.size)

        I420Motion.warp(src, width, height, FrameMotion(0.0, 0.0, 0.5, 0.0), out)

        // The corner is outside the shrunken picture.
        assertEquals(16, luma(out, width, 0, 0))
        // The center still shows the center.
        val center = luma(out, width, 4, 4)
        assertTrue(center in luma(src, width, 3, 3)..luma(src, width, 5, 5))
        // Chroma stays neutral where the picture is gone.
        assertEquals(128, out[width * height].toInt() and 0xFF)
    }

    @Test
    fun `the warp shifts the picture by a fraction of the frame`() {
        val width = 8
        val height = 4
        val src = gradientFrame(width, height)
        val out = ByteArray(src.size)

        I420Motion.warp(src, width, height, FrameMotion(0.5, 0.0, 1.0, 0.0), out)

        // Half a frame to the right: the left half is black, the right half
        // shows what the left half showed.
        assertEquals(16, luma(out, width, 1, 2))
        assertEquals(luma(src, width, 0, 2), luma(out, width, 4, 2))
        assertEquals(luma(src, width, 2, 2), luma(out, width, 6, 2))
    }

    private fun gradientFrame(width: Int, height: Int): ByteArray {
        val frame = ByteArray(width * height * 3 / 2) { 128.toByte() }
        for (y in 0 until height) {
            for (x in 0 until width) {
                frame[y * width + x] = (40 + x * 20 + y).toByte()
            }
        }
        return frame
    }

    private fun luma(frame: ByteArray, width: Int, x: Int, y: Int): Int =
        frame[y * width + x].toInt() and 0xFF
}
