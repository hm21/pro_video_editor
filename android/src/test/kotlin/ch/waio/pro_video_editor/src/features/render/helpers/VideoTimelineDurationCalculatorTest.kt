package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals

internal class VideoTimelineDurationCalculatorTest {
    @Test
    fun renderedClipDurationUs_appliesGlobalPlaybackSpeed() {
        assertEquals(
            15_000_000L,
            VideoTimelineDurationCalculator.renderedClipDurationUs(
                sourceDurationUs = 30_000_000L,
                clipPlaybackSpeed = null,
                globalPlaybackSpeed = 2f
            )
        )
    }

    @Test
    fun renderedClipDurationUs_appliesPerClipPlaybackSpeed() {
        assertEquals(
            5_000_000L,
            VideoTimelineDurationCalculator.renderedClipDurationUs(
                sourceDurationUs = 10_000_000L,
                clipPlaybackSpeed = 2f,
                globalPlaybackSpeed = null
            )
        )
    }

    @Test
    fun renderedClipDurationUs_combinesGlobalAndPerClipPlaybackSpeed() {
        assertEquals(
            2_500_000L,
            VideoTimelineDurationCalculator.renderedClipDurationUs(
                sourceDurationUs = 10_000_000L,
                clipPlaybackSpeed = 2f,
                globalPlaybackSpeed = 2f
            )
        )
    }

    @Test
    fun renderedClipDurationUs_slowsDownWhenPlaybackSpeedIsBelowOne() {
        assertEquals(
            20_000_000L,
            VideoTimelineDurationCalculator.renderedClipDurationUs(
                sourceDurationUs = 10_000_000L,
                clipPlaybackSpeed = 0.5f,
                globalPlaybackSpeed = null
            )
        )
    }
}
