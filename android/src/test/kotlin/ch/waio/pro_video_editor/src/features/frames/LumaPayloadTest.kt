package ch.waio.pro_video_editor.src.features.frames

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertSame

internal class LumaPayloadTest {

    @Test
    fun resized_keepsAFrameOfTheRequestedSize() {
        val frame = LumaPayload(2, 2, byteArrayOf(0, 50, 100, 200.toByte()))
        assertSame(frame, frame.resized(2, 2))
    }

    @Test
    fun resized_bringsAFramePixelOffToTheStreamsSize() {
        // A 4 x 3 ramp resampled to 4 x 2, as a fallback a pixel taller than
        // the first frame would be.
        val ramp = ByteArray(12) { (it % 4 * 60).toByte() }
        val resized = LumaPayload(4, 3, ramp).resized(4, 2)
        assertEquals(4, resized.width)
        assertEquals(2, resized.height)
        val row = byteArrayOf(0, 60, 120, 180.toByte())
        assertContentEquals(row + row, resized.luma)
    }

    @Test
    fun resized_interpolatesBetweenPixels() {
        val resized = LumaPayload(2, 1, byteArrayOf(0, 200.toByte())).resized(4, 1)
        assertContentEquals(
            listOf(0, 50, 150, 200),
            resized.luma.map { it.toInt() and 0xFF },
        )
    }
}
