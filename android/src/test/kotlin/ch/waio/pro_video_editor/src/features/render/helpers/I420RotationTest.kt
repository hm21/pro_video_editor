package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotSame
import kotlin.test.assertSame

internal class I420RotationTest {

    // A 4×2 frame: Y rows "abcd" / "efgh", then U "12" and V "34".
    private val width = 4
    private val height = 2
    private val frame = "abcdefgh1234".toByteArray()

    @Test
    fun quarterTurns_wrapsAndRoundsDownToWholeTurns() {
        assertEquals(0, I420Rotation.quarterTurns(0))
        assertEquals(1, I420Rotation.quarterTurns(90))
        assertEquals(2, I420Rotation.quarterTurns(180))
        assertEquals(3, I420Rotation.quarterTurns(270))
        assertEquals(3, I420Rotation.quarterTurns(-90))
        assertEquals(1, I420Rotation.quarterTurns(450))
        assertEquals(0, I420Rotation.quarterTurns(45))
        assertEquals(1, I420Rotation.quarterTurns(135))
    }

    @Test
    fun displaySize_swapsAxesForQuarterTurnsOnly() {
        assertEquals(4 to 2, I420Rotation.displaySize(4, 2, 0))
        assertEquals(2 to 4, I420Rotation.displaySize(4, 2, 90))
        assertEquals(4 to 2, I420Rotation.displaySize(4, 2, 180))
        assertEquals(2 to 4, I420Rotation.displaySize(4, 2, 270))
        assertEquals(2 to 4, I420Rotation.displaySize(4, 2, -90))
    }

    @Test
    fun displaySize_agreesWithRotateForAnglesBetweenQuarterTurns() {
        // 45° rotates by nothing, so the size must stay as coded; 135° rotates
        // by one quarter turn, so it must swap.
        assertEquals(4 to 2, I420Rotation.displaySize(4, 2, 45))
        assertContentEquals(frame, I420Rotation.rotate(frame, width, height, 45))
        assertEquals(2 to 4, I420Rotation.displaySize(4, 2, 135))
        assertContentEquals(
            I420Rotation.rotate(frame, width, height, 90),
            I420Rotation.rotate(frame, width, height, 135),
        )
    }

    @Test
    fun rotate_zeroCopiesTheFrame() {
        val copy = I420Rotation.rotate(frame, width, height, 0)
        assertNotSame(frame, copy)
        assertContentEquals(frame, copy)
        assertContentEquals(frame, I420Rotation.rotate(frame, width, height, 360))
    }

    @Test
    fun rotate_writesIntoTheGivenDestination() {
        val dst = ByteArray(frame.size)
        assertSame(dst, I420Rotation.rotate(frame, width, height, 90, dst))
        assertContentEquals("eafbgchd1234".toByteArray(), dst)
        assertSame(dst, I420Rotation.rotate(frame, width, height, 0, dst))
        assertContentEquals(frame, dst)
    }

    @Test
    fun rotate_refusesAQuarterTurnInPlaceButAllowsTheIdentity() {
        assertFailsWith<IllegalArgumentException> {
            I420Rotation.rotate(frame, width, height, 90, frame)
        }
        assertSame(frame, I420Rotation.rotate(frame, width, height, 0, frame))
        assertContentEquals("abcdefgh1234".toByteArray(), frame)
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
    fun rotate_stridesTheChromaPlanesByTheirOwnWidth() {
        // A 4×4 frame whose chroma planes are 2×2, so their rows are shorter
        // than the luma rows: Y "abcd" / "efgh" / "ijkl" / "mnop", U "12" /
        // "34", V "56" / "78".
        val square = "abcdefghijklmnop12345678".toByteArray()
        // 90°: Y "miea" / "njfb" / "okgc" / "plhd"; U "31" / "42"; V "75" / "86".
        assertContentEquals(
            "mieanjfbokgcplhd31427586".toByteArray(),
            I420Rotation.rotate(square, 4, 4, 90),
        )
        // 270°: Y "dhlp" / "cgko" / "bfjn" / "aeim"; U "24" / "13"; V "68" / "57".
        assertContentEquals(
            "dhlpcgkobfjnaeim24136857".toByteArray(),
            I420Rotation.rotate(square, 4, 4, 270),
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
