package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.math.roundToLong

internal object VideoTimelineDurationCalculator {
    fun renderedClipDurationUs(
        sourceDurationUs: Long,
        clipPlaybackSpeed: Float?,
        globalPlaybackSpeed: Float?
    ): Long {
        val effectiveSpeed = validSpeedOrOne(clipPlaybackSpeed) *
                validSpeedOrOne(globalPlaybackSpeed)
        return (sourceDurationUs.coerceAtLeast(0L).toDouble() / effectiveSpeed).roundToLong()
    }

    private fun validSpeedOrOne(speed: Float?): Double {
        return if (speed != null && speed > 0f) speed.toDouble() else 1.0
    }
}
