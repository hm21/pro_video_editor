package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class CustomVideoEffectHistoryTest {

    /** Presentation times of a 30 fps stream, which alternate 33333 and 33334 µs steps. */
    private fun frameTimeUs(index: Int): Long = index * 1_000_000L / 30

    /** Records frames 0 until [count] into slots of the same number, freeing what it is told. */
    private fun recordFrames(history: CustomVideoEffectHistory, count: Int): MutableSet<Int> {
        val live = mutableSetOf<Int>()
        for (i in 0 until count) {
            live += i
            live -= history.record(frameTimeUs(i), slot = i).toSet()
        }
        return live
    }

    @Test
    fun lookup_findsTheFrameExactlyThreeBackDespiteRoundedTimestamps() {
        val history = CustomVideoEffectHistory(longArrayOf(100_000))
        // Each frame is looked up before it is kept, as the renderer does.
        for (i in 0 until 30) {
            val found = history.lookup(frameTimeUs(i)).single()
            if (i < 3) assertNull(found, "frame $i") else assertEquals(i - 3, found?.slot, "frame $i")
            history.record(frameTimeUs(i), slot = i)
        }
    }

    @Test
    fun lookup_isNullUntilTheClipHasPlayedThatFar() {
        val history = CustomVideoEffectHistory(longArrayOf(100_000, 200_000))
        recordFrames(history, 4)
        val found = history.lookup(frameTimeUs(4))
        assertEquals(1, found[0]?.slot)
        assertNull(found[1])
    }

    @Test
    fun record_keepsOnlyWhatLaterFramesCanStillAskFor() {
        val history = CustomVideoEffectHistory(longArrayOf(100_000, 200_000))
        val live = recordFrames(history, 60)
        // 200 ms is six frames: the frame six back from the newest is the
        // oldest a later frame can need, so seven frames stay.
        assertEquals(7, history.size)
        assertEquals((53 until 60).toSet(), live)
    }

    @Test
    fun record_startsOverWhenTimeGoesBackwards() {
        val history = CustomVideoEffectHistory(longArrayOf(100_000))
        recordFrames(history, 10)
        val freed = history.record(frameTimeUs(2), slot = 99)
        assertTrue(freed.isNotEmpty())
        assertEquals(1, history.size)
        assertNull(history.lookup(frameTimeUs(3)).single())
    }

    @Test
    fun record_neverKeepsMoreThanItsCapacity() {
        // An offset far longer than the capacity covers.
        val history = CustomVideoEffectHistory(longArrayOf(60_000_000), capacity = 5)
        recordFrames(history, 20)
        assertEquals(5, history.size)
    }

    @Test
    fun clear_freesEverySlot() {
        val history = CustomVideoEffectHistory(longArrayOf(100_000))
        val live = recordFrames(history, 10)
        assertEquals(live, history.clear().toSet())
        assertEquals(0, history.size)
    }

    @Test
    fun isUsed_isFalseWithoutOffsets() {
        val history = CustomVideoEffectHistory(LongArray(0))
        assertEquals(false, history.isUsed)
        assertEquals(0L, history.maxOffsetUs)
    }
}
