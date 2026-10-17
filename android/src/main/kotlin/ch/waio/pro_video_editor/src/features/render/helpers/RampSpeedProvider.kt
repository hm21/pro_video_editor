package ch.waio.pro_video_editor.src.features.render.helpers

import androidx.media3.common.C
import androidx.media3.common.audio.SpeedProvider
import ch.waio.pro_video_editor.src.features.render.models.SpeedRamp
import kotlin.math.roundToLong

/**
 * Plays a [SpeedRamp] through Media3: the speed of the step at a time into the
 * clip, and where the next step starts.
 *
 * Times count in source microseconds from the clip's first frame, which is
 * what both [androidx.media3.effect.SpeedChangeEffect] and
 * [androidx.media3.common.audio.SpeedChangingAudioProcessor] hand a provider
 * for one media item of a sequence.
 *
 * The step boundaries are rounded to whole microseconds once, here, so a time
 * on a boundary belongs to the step that starts there and the next change is
 * always later than the time asked about, as Media3 requires. A step shorter
 * than a microsecond is dropped.
 */
internal class RampSpeedProvider(ramp: SpeedRamp, sourceDurationUs: Long) : SpeedProvider {
    private val startsUs: LongArray
    private val speeds: FloatArray

    init {
        val starts = ArrayList<Long>(ramp.steps.size)
        val stepSpeeds = ArrayList<Float>(ramp.steps.size)
        for (step in ramp.steps) {
            val startUs = if (starts.isEmpty()) 0L else (step.start * sourceDurationUs).roundToLong()
            if (starts.isNotEmpty() && startUs <= starts.last()) {
                // Too short to start after the step before it: that step takes
                // this one's speed from here on instead.
                stepSpeeds[stepSpeeds.size - 1] = step.speed.toFloat()
                continue
            }
            starts += startUs
            stepSpeeds += step.speed.toFloat()
        }
        startsUs = starts.toLongArray()
        speeds = stepSpeeds.toFloatArray()
    }

    override fun getSpeed(timeUs: Long): Float = speeds[indexAt(timeUs)]

    override fun getNextSpeedChangeTimeUs(timeUs: Long): Long =
        startsUs.getOrNull(indexAt(timeUs) + 1) ?: C.TIME_UNSET

    /** The last step that starts at or before [timeUs]. */
    private fun indexAt(timeUs: Long): Int {
        val found = startsUs.binarySearch(timeUs)
        return if (found >= 0) found else maxOf(0, -found - 2)
    }
}
