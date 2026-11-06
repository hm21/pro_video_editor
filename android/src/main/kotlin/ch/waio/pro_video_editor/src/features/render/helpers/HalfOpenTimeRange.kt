package ch.waio.pro_video_editor.src.features.render.helpers

import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.GlEffect
import androidx.media3.effect.TimestampWrapper

/**
 * [effect] applied from [startTimeUs] up to, but not including, [endTimeUs]
 * (`-1` = from the start, until the end).
 *
 * Image layers and color filters keep to the rule clips and video effects
 * follow: a frame at exactly [endTimeUs] shows what comes after the range, and
 * of two ranges that meet there only the later one shows.
 *
 * [TimestampWrapper] includes its end, so it ends on the microsecond before
 * [endTimeUs]: frame times are whole microseconds, so that is the last one a
 * frame inside the range can sit on. Check [isEmptyTimeRange] first; the
 * wrapper rejects a range that leaves no microsecond after its start.
 */
@UnstableApi
internal fun halfOpenTimestampWrapper(
    effect: GlEffect,
    startTimeUs: Long,
    endTimeUs: Long,
): TimestampWrapper {
    val start = if (startTimeUs == -1L) 0L else startTimeUs
    val end = if (endTimeUs == -1L) Long.MAX_VALUE else endTimeUs - 1
    return TimestampWrapper(effect, start, end)
}

/**
 * Whether something shown from [startTimeUs] up to, but not including,
 * [endTimeUs] (`-1` = from the start, until the end) cannot be wrapped by
 * [halfOpenTimestampWrapper], and is left out.
 *
 * That is a range that shows no frame, and one of a single microsecond: the
 * wrapper would have to end where it starts, which [TimestampWrapper] rejects.
 * Such a range can hold at most a frame at exactly [startTimeUs].
 */
internal fun isEmptyTimeRange(startTimeUs: Long, endTimeUs: Long): Boolean {
    if (startTimeUs < -1L) return true
    if (endTimeUs == -1L) return false
    val start = if (startTimeUs == -1L) 0L else startTimeUs
    return endTimeUs <= start || endTimeUs - start < 2L
}
