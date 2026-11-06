package ch.waio.pro_video_editor.src.features.render.helpers

import androidx.media3.common.Effect
import androidx.media3.effect.GlEffect
import androidx.media3.effect.TextureOverlay
import androidx.media3.effect.TimestampWrapper
import applyColorMatrix
import ch.waio.pro_video_editor.src.features.render.models.ColorFilterConfig
import org.mockito.Mockito.mock
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Pins that image layers and color filters show from their start up to, but
 * not including, their end, as clips and video effects do.
 *
 * Media3's [TimestampWrapper] applies its effect to a frame at exactly its end
 * time too, so a layer handed its own end would still show on the frame where
 * the next one starts, which the iOS and macOS compositor does not draw.
 */
internal class HalfOpenTimeRangeTest {

    private val effect = mock(GlEffect::class.java)

    /** Whether [wrapper] applies its effect at [timeUs], as Media3 decides it. */
    private fun shows(wrapper: TimestampWrapper, timeUs: Long) =
        timeUs >= wrapper.startTimeUs && timeUs <= wrapper.endTimeUs

    @Test
    fun aWrapperEndsTheMicrosecondBeforeTheRangeEnds() {
        val wrapper = halfOpenTimestampWrapper(effect, 1_000L, 2_000L)

        assertEquals(1_000L, wrapper.startTimeUs)
        assertEquals(1_999L, wrapper.endTimeUs)
        assertTrue(shows(wrapper, 1_000L))
        assertTrue(shows(wrapper, 1_999L))
        assertFalse(shows(wrapper, 2_000L))
    }

    @Test
    fun aRangeFromTheStartBeginsAtZero() {
        val wrapper = halfOpenTimestampWrapper(effect, -1L, 2_000L)

        assertEquals(0L, wrapper.startTimeUs)
        assertEquals(1_999L, wrapper.endTimeUs)
    }

    @Test
    fun aRangeUntilTheEndKeepsNoEnd() {
        val wrapper = halfOpenTimestampWrapper(effect, 1_000L, -1L)

        assertEquals(1_000L, wrapper.startTimeUs)
        assertEquals(Long.MAX_VALUE, wrapper.endTimeUs)
    }

    @Test
    fun ofTwoRangesThatMeetOnlyTheLaterOneShowsWhereTheyMeet() {
        // Like the frames of a text whose words light up one by one: each part
        // ends where the next one starts.
        val first = halfOpenTimestampWrapper(effect, 0L, 1_000L)
        val second = halfOpenTimestampWrapper(effect, 1_000L, 2_000L)

        assertFalse(shows(first, 1_000L))
        assertTrue(shows(second, 1_000L))
        // And no microsecond in between is left without either.
        assertEquals(first.endTimeUs + 1, second.startTimeUs)
    }

    @Test
    fun emptyTimeRanges() {
        assertFalse(isEmptyTimeRange(-1L, -1L))
        assertFalse(isEmptyTimeRange(-1L, 2L))
        assertFalse(isEmptyTimeRange(5L, -1L))
        assertFalse(isEmptyTimeRange(5L, 7L))
        assertTrue(isEmptyTimeRange(-1L, 0L))
        assertTrue(isEmptyTimeRange(5L, 5L))
        assertTrue(isEmptyTimeRange(5L, 4L))
        assertTrue(isEmptyTimeRange(-2L, 4L))
        assertTrue(isEmptyTimeRange(5L, Long.MIN_VALUE))
    }

    @Test
    fun aRangeOfOneMicrosecondIsEmpty() {
        // Media3 cannot end the wrapper where it starts.
        assertTrue(isEmptyTimeRange(5L, 6L))
        assertTrue(isEmptyTimeRange(-1L, 1L))
        assertFailsWith<IllegalArgumentException> { halfOpenTimestampWrapper(effect, 5L, 6L) }
    }

    @Test
    fun everyRangeThatIsNotEmptyCanBeWrapped() {
        val ranges = listOf(-1L to 2L, 0L to 2L, 5L to 7L, 5L to -1L, -1L to Long.MAX_VALUE)

        for ((start, end) in ranges) {
            assertFalse(isEmptyTimeRange(start, end), "$start..$end")
            halfOpenTimestampWrapper(effect, start, end)
        }
    }

    @Test
    fun anOverlayShownForOneMicrosecondIsLeftOut() {
        val effects = mutableListOf<Effect>()
        val batch = OverlayBatch(effects)

        batch.add(mock(TextureOverlay::class.java), 1_000L, 1_001L)
        batch.flush()

        assertTrue(effects.isEmpty())
    }

    @Test
    fun aTimedColorFilterEndsTheMicrosecondBeforeItsEnd() {
        val effects = mutableListOf<Effect>()

        applyColorMatrix(effects, listOf(ColorFilterConfig(identity, 1_000L, 2_000L)))

        val wrapper = assertIs<TimestampWrapper>(effects.single())
        assertEquals(1_000L, wrapper.startTimeUs)
        assertEquals(1_999L, wrapper.endTimeUs)
    }

    @Test
    fun aTimedColorFilterFromTheStartOrUntilTheEndKeepsTheOpenSide() {
        val effects = mutableListOf<Effect>()

        applyColorMatrix(
            effects,
            listOf(
                ColorFilterConfig(identity, null, 2_000L),
                ColorFilterConfig(identity, 1_000L, null),
            )
        )

        val fromStart = assertIs<TimestampWrapper>(effects[0])
        assertEquals(0L, fromStart.startTimeUs)
        assertEquals(1_999L, fromStart.endTimeUs)
        val untilEnd = assertIs<TimestampWrapper>(effects[1])
        assertEquals(1_000L, untilEnd.startTimeUs)
        assertEquals(Long.MAX_VALUE, untilEnd.endTimeUs)
    }

    @Test
    fun aTimedColorFilterThatShowsNoFrameIsLeftOutInsteadOfFailingTheRender() {
        val effects = mutableListOf<Effect>()

        applyColorMatrix(
            effects,
            listOf(
                ColorFilterConfig(identity, 1_000L, 1_001L),
                ColorFilterConfig(identity, null, 0L),
            )
        )

        assertTrue(effects.isEmpty())
    }

    private val identity = listOf(
        1.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 1.0, 0.0,
    )
}
