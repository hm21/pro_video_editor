package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals

internal class PictureStartSnappingTest {
    /** Picture [index] of a 30 fps clip, truncated to whole microseconds. */
    private fun picture(index: Int): Long = index * 100_000L / 3

    /** [decodeOrder] as pictures, whatever time the search starts from. */
    private fun snapped(timeUs: Long, decodeOrder: List<Int>): Long =
        PictureStartSnapping.snapped(timeUs) { decodeOrder.asSequence().map(::picture) }

    private val inOrder = (0 until 30).toList()

    /** I0 P3 B1 B2 P6 B4 B5 …: every B-frame comes after the P-frame it precedes. */
    private val bFrames = (0 until 30 step 3).flatMap { listOf(it + 3, it + 1, it + 2) }
        .let { listOf(0) + it }

    @Test
    fun aTimeRoundedUpFromAPictureMovesOntoIt() {
        // Picture 2 starts at 66666.67 µs, which rounds up to 66667.
        assertEquals(picture(2), snapped(66_667, inOrder))
        assertEquals(picture(2), snapped(66_667, bFrames))
    }

    @Test
    fun aTimeOnASampleOrJustBeforeOneStays() {
        assertEquals(66_666, snapped(66_666, bFrames))
        assertEquals(66_665, snapped(66_665, bFrames))
        // Picture 3 starts on a whole microsecond.
        assertEquals(99_999, snapped(99_999, bFrames))
    }

    @Test
    fun aTimeTwoMicrosecondsPastAPictureStays() {
        assertEquals(66_668, snapped(66_668, bFrames))
    }

    @Test
    fun theSearchEndsOncePicturesThatFollowItCanNoLongerBeReordered() {
        // Seventeen later pictures decoded ahead of picture 2 is more than
        // H.264 and HEVC allow, so the search stops before reaching it.
        val ahead = (3..19).toList()
        assertEquals(66_667, snapped(66_667, ahead + 2))
        assertEquals(picture(2), snapped(66_667, ahead.drop(1) + 2))
    }

    @Test
    fun aClipWithoutSamplesKeepsItsTrim() {
        assertEquals(66_667, snapped(66_667, emptyList()))
    }
}
