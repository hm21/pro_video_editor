package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.SpeedRamp
import kotlin.math.roundToLong

internal object VideoTimelineDurationCalculator {
    /**
     * Output duration of [sourceDurationUs] of a clip, after its own speed —
     * [clipSpeedRamp] when it has one, else [clipPlaybackSpeed] — and the
     * render-wide [globalPlaybackSpeed].
     */
    fun renderedClipDurationUs(
        sourceDurationUs: Long,
        clipPlaybackSpeed: Float?,
        globalPlaybackSpeed: Float?,
        clipSpeedRamp: SpeedRamp? = null,
    ): Long {
        val source = sourceDurationUs.coerceAtLeast(0L).toDouble()
        val clipOutput = clipSpeedRamp?.let { source * it.durationFactor }
            ?: (source / validSpeedOrOne(clipPlaybackSpeed))
        return (clipOutput / validSpeedOrOne(globalPlaybackSpeed)).roundToLong()
    }

    private fun validSpeedOrOne(speed: Float?): Double {
        return if (speed != null && speed > 0f) speed.toDouble() else 1.0
    }
}
