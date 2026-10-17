package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals

/** The transitions [ClipTransitionRenderer.blendFrame] draws itself. */
internal class ClipTransitionRendererTest {

    private val width = 8
    private val height = 4

    /** A packed I420 frame whose luma at column x is [luma] + x and whose chroma is flat. */
    private fun frame(luma: Int): ByteArray {
        val out = ByteArray(width * height * 3 / 2) { 128.toByte() }
        for (y in 0 until height) for (x in 0 until width) out[y * width + x] = (luma + x).toByte()
        return out
    }

    private val outgoing = frame(10)
    private val incoming = frame(100)

    private fun row(frame: ByteArray, y: Int = 0) =
        (0 until width).map { frame[y * width + it].toInt() and 0xFF }

    private fun column(frame: ByteArray, x: Int = 0) =
        (0 until height).map { frame[it * width + x].toInt() and 0xFF }

    private fun blend(type: String, direction: String, p: Double) =
        ClipTransitionRenderer.blendFrame(outgoing, incoming, width, height, p, type, direction)

    @Test
    fun dissolveMixesBothFramesByTheProgress() {
        assertEquals((0 until width).map { 55 + it }, row(blend("dissolve", "left", 0.5)))
        assertEquals((0 until width).map { 33 + it }, row(blend("dissolve", "left", 0.25)))
    }

    @Test
    fun wipeRevealsTheIncomingFrameFromTheEdgeItSweepsAway() {
        assertEquals(listOf(100, 101, 102, 103, 14, 15, 16, 17), row(blend("wipe", "right", 0.5)))
        assertEquals(listOf(10, 11, 12, 13, 104, 105, 106, 107), row(blend("wipe", "left", 0.5)))
        assertEquals(listOf(100, 100, 10, 10), column(blend("wipe", "down", 0.5)))
    }

    @Test
    fun slideMovesOnlyTheIncomingFrame() {
        // Moving left, the incoming frame's left half covers the right half.
        assertEquals(listOf(10, 11, 12, 13, 100, 101, 102, 103), row(blend("slide", "left", 0.5)))
        assertEquals(listOf(104, 105, 106, 107, 14, 15, 16, 17), row(blend("slide", "right", 0.5)))
    }

    @Test
    fun pushMovesBothFramesTogether() {
        assertEquals(listOf(14, 15, 16, 17, 100, 101, 102, 103), row(blend("push", "left", 0.5)))
        assertEquals(listOf(104, 105, 106, 107, 10, 11, 12, 13), row(blend("push", "right", 0.5)))
    }

    @Test
    fun startsOnTheOutgoingFrameAndEndsOnTheIncomingOne() {
        for (type in listOf("dissolve", "wipe", "slide", "push")) {
            for (direction in listOf("left", "right", "up", "down")) {
                assertEquals(outgoing.toList(), blend(type, direction, 0.0).toList(), "$type $direction 0")
                assertEquals(incoming.toList(), blend(type, direction, 1.0).toList(), "$type $direction 1")
            }
        }
    }
}
