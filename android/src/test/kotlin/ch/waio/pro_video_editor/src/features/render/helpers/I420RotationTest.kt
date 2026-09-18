package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertSame

internal class I420RotationTest {

    // A 4×2 frame: Y rows "abcd" / "efgh", then U "12" and V "34".
    private val width = 4
    private val height = 2
    private val frame = "abcdefgh1234".toByteArray()

    @Test
    fun displaySize_swapsAxesForQuarterTurnsOnly() {
        assertEquals(4 to 2, I420Rotation.displaySize(4, 2, 0))
        assertEquals(2 to 4, I420Rotation.displaySize(4, 2, 90))
        assertEquals(4 to 2, I420Rotation.displaySize(4, 2, 180))
        assertEquals(2 to 4, I420Rotation.displaySize(4, 2, 270))
        assertEquals(2 to 4, I420Rotation.displaySize(4, 2, -90))
    }

    @Test
    fun rotate_zeroReturnsTheSameFrame() {
        assertSame(frame, I420Rotation.rotate(frame, width, height, 0))
        assertSame(frame, I420Rotation.rotate(frame, width, height, 360))
    }

    @Test
    fun rotate_90ClockwiseTurnsTheLeftColumnIntoTheTopRow() {
        // 2 wide, 4 tall: "ea" / "fb" / "gc" / "hd"; U "1" / "2"; V "3" / "4".
        assertContentEquals(
            "eafbgchd1234".toByteArray(),
            I420Rotation.rotate(frame, width, height, 90),
        )
    }

    @Test
    fun rotate_180ReadsEveryPlaneBackToFront() {
        assertContentEquals(
            "hgfedcba2143".toByteArray(),
            I420Rotation.rotate(frame, width, height, 180),
        )
    }

    @Test
    fun rotate_270ClockwiseTurnsTheRightColumnIntoTheTopRow() {
        // 2 wide, 4 tall: "dh" / "cg" / "bf" / "ae"; U "2" / "1"; V "4" / "3".
        assertContentEquals(
            "dhcgbfae2143".toByteArray(),
            I420Rotation.rotate(frame, width, height, 270),
        )
    }

    @Test
    fun rotate_negativeAndOverflowingAnglesAreNormalized() {
        assertContentEquals(
            I420Rotation.rotate(frame, width, height, 270),
            I420Rotation.rotate(frame, width, height, -90),
        )
        assertContentEquals(
            I420Rotation.rotate(frame, width, height, 90),
            I420Rotation.rotate(frame, width, height, 450),
        )
    }

    @Test
    fun rotate_quarterTurnAndItsInverseRoundTrip() {
        val turned = I420Rotation.rotate(frame, width, height, 90)
        // The turned frame is 2×4, so the inverse rotates those dimensions.
        assertContentEquals(frame, I420Rotation.rotate(turned, height, width, 270))
    }
}
