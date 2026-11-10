package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

internal class FrameBlendScheduleTest {

    private val frameUs = 33_333L

    /** The frames a clip at [speed] puts out between its first two frames. */
    private fun firstGap(speed: Double): List<BlendedFrame> =
        FrameBlendSchedule.between(
            previousUs = 0L,
            currentUs = (frameUs / speed).toLong(),
            originUs = 0L,
            frameUs = frameUs,
        )

    @Test
    fun halfSpeed_mixesHalfwayBetweenSourceFrames() {
        assertEquals(
            listOf(BlendedFrame(0L, 0f), BlendedFrame(frameUs, 0.5f)),
            firstGap(0.5),
        )
    }

    @Test
    fun quarterSpeed_mixesInQuarterSteps() {
        assertEquals(listOf(0f, 0.25f, 0.5f, 0.75f), firstGap(0.25).map { it.weight })
        assertEquals(
            listOf(0L, frameUs, 2 * frameUs, 3 * frameUs),
            firstGap(0.25).map { it.presentationTimeUs },
        )
    }

    @Test
    fun threeQuarterSpeed_keepsTheSourceFrameRate() {
        // 44 ms between source frames: the grid frames fall at varying
        // places between them, and every one is still blended.
        val frames = (0 until 3).flatMap { k ->
            FrameBlendSchedule.between(
                previousUs = k * 44_444L,
                currentUs = (k + 1) * 44_444L,
                originUs = 0L,
                frameUs = frameUs,
            )
        }

        assertEquals(
            listOf(0L, frameUs, 2 * frameUs, 3 * frameUs),
            frames.map { it.presentationTimeUs },
        )
        assertEquals(0f, frames[0].weight)
        assertEquals(0.75f, frames[1].weight, 0.001f)
        assertEquals(0.5f, frames[2].weight, 0.001f)
        assertEquals(0.25f, frames[3].weight, 0.001f)
    }

    @Test
    fun ownSpeed_showsEverySourceFrameOnceUnmixed() {
        // Timestamps up to a millisecond off the grid, as a camera writes them.
        val pts = listOf(0L, 34_100L, 66_200L, 100_900L)
        val shown = pts.zipWithNext { previous, current ->
            FrameBlendSchedule.between(previous, current, 0L, frameUs).map {
                assertTrue(it.weight == 0f || it.weight == 1f)
                it.presentationTimeUs to if (it.weight == 0f) previous else current
            }
        }.flatten()

        assertEquals(
            listOf(0L to 0L, frameUs to 34_100L, 2 * frameUs to 66_200L, 3 * frameUs to 100_900L),
            shown,
        )
    }

    @Test
    fun doubleSpeed_skipsEverySecondSourceFrame() {
        val pts = (0..4).map { it * frameUs / 2 }
        val frames = pts.zipWithNext { previous, current ->
            FrameBlendSchedule.between(previous, current, 0L, frameUs)
        }

        assertEquals(listOf(1, 0, 1, 0), frames.map { it.size })
        assertTrue(frames.flatten().all { it.weight == 0f })
    }

    @Test
    fun aFrameNextToASourceFrameShowsItAlone() {
        val nearPrevious = FrameBlendSchedule.between(
            previousUs = frameUs - 500L,
            currentUs = 3 * frameUs,
            originUs = 0L,
            frameUs = frameUs,
        )

        assertEquals(0f, nearPrevious.first().weight)
    }

    @Test
    fun theGridCountsFromTheClipsFirstFrame() {
        val frames = FrameBlendSchedule.between(
            previousUs = 1_000_000L,
            currentUs = 1_000_000L + 2 * frameUs,
            originUs = 1_000_000L,
            frameUs = frameUs,
        )

        assertEquals(
            listOf(1_000_000L, 1_000_000L + frameUs),
            frames.map { it.presentationTimeUs },
        )
    }
}
