package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Pins which captured frame of a blended video layer goes with a composed
 * frame: the one Media3's compositor would have drawn, the closest in time and
 * the earlier of two equally close, with the frames before it let go.
 *
 * Scope: the choice only. The capture and the blend are GL programs, covered
 * by the example's `layer_blend_test` integration test.
 */
internal class CapturedTimelineTest {

    private val dropped = mutableListOf<String>()

    private fun timeline(vararg frames: Pair<Long, String>) = CapturedTimeline<String>().apply {
        for ((time, frame) in frames) add(time, frame) { dropped += it }
    }

    @Test
    fun takesTheFrameAtTheComposedTime() {
        val frames = timeline(0L to "a", 33_333L to "b", 66_666L to "c")

        assertEquals("b", frames.take(33_333L) { dropped += it })
        assertEquals(listOf("a"), dropped)
    }

    @Test
    fun takesTheClosestFrameOfALayerOfAnotherFrameRate() {
        // A 24 fps layer under a 30 fps primary sequence.
        val frames = timeline(0L to "a", 41_666L to "b", 83_333L to "c")

        assertEquals("b", frames.take(33_333L) { dropped += it })
        // 16.7 ms from c, 25 ms from b.
        assertEquals("c", frames.take(66_666L) { dropped += it })
        assertEquals("c", frames.take(100_000L) { dropped += it })
        assertEquals(listOf("a", "b"), dropped)
    }

    @Test
    fun takesTheEarlierOfTwoEquallyCloseFrames() {
        val frames = timeline(0L to "a", 20_000L to "b")

        assertEquals("a", frames.take(10_000L) { dropped += it })
        assertEquals(2, frames.size)
    }

    @Test
    fun keepsTheChosenFrameForTheNextComposedFrame() {
        val frames = timeline(0L to "a", 100_000L to "b")

        assertEquals("a", frames.take(33_333L) { dropped += it })
        assertEquals("b", frames.take(66_666L) { dropped += it })
        assertEquals(listOf("a"), dropped)
        assertEquals(1, frames.size)
    }

    @Test
    fun takesTheLastFrameOnceTheLayerHasNoLaterOne() {
        val frames = timeline(0L to "a", 33_333L to "b")

        assertEquals("b", frames.take(500_000L) { dropped += it })
    }

    @Test
    fun aFrameWithNothingToDrawIsChosenAsAnyOther() {
        // A gap item records null: the layer shows nothing at that time.
        val frames = CapturedTimeline<String?>().apply {
            add(0L, "clip") {}
            add(33_333L, null) {}
        }

        assertNull(frames.take(33_333L) {})
    }

    @Test
    fun takesNothingBeforeAnyFrameIsCaptured() {
        assertNull(CapturedTimeline<String>().take(0L) { dropped += it })
    }

    @Test
    fun aSecondFrameAtTheSameTimeReplacesTheFirst() {
        val frames = timeline(0L to "a")
        frames.add(0L, "b") { dropped += it }

        assertEquals(listOf("a"), dropped)
        assertEquals("b", frames.take(0L) {})
    }

    @Test
    fun clearLetsGoOfEveryFrame() {
        val frames = timeline(0L to "a", 33_333L to "b")

        frames.clear { dropped += it }

        assertEquals(listOf("a", "b"), dropped)
        assertEquals(0, frames.size)
    }
}
