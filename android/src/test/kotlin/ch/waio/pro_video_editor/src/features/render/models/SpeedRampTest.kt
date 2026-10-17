package ch.waio.pro_video_editor.src.features.render.models

import ch.waio.pro_video_editor.src.features.render.helpers.RampSpeedProvider
import androidx.media3.common.C
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

internal class SpeedRampTest {
    // Fast, slow motion, fast: 0.4 of the source at 2x, 0.2 at 0.25x, 0.4 at 2x.
    private val ramp = SpeedRamp(
        listOf(
            SpeedRamp.Step(0.0, 0.4, 2.0),
            SpeedRamp.Step(0.4, 0.6, 0.25),
            SpeedRamp.Step(0.6, 1.0, 2.0),
        )
    )

    @Test
    fun durationFactor_sumsEveryStepAtItsSpeed() {
        // 0.2 + 0.8 + 0.2
        assertEquals(1.2, ramp.durationFactor, 1e-12)
        assertEquals(3_600_000L, ramp.outputDurationUs(3_000_000L))
    }

    @Test
    fun headAndTailSourceUs_followTheStepsAtEitherEnd() {
        // The first 0.6 s of output plays 1.2 s of source at 2x.
        assertEquals(1_200_000L, ramp.headSourceUs(600_000L, 3_000_000L))
        // The last 1.0 s of output: 1.2 s of source at 2x, then 0.1 s at 0.25x.
        assertEquals(1_300_000L, ramp.tailSourceUs(1_000_000L, 3_000_000L))
    }

    @Test
    fun cropped_keepsTheSpeedsOfThePartThatStillPlays() {
        val tail = ramp.cropped(0.5, 1.0)!!

        assertEquals(
            listOf(SpeedRamp.Step(0.0, 0.2, 0.25), SpeedRamp.Step(0.2, 1.0, 2.0)),
            tail.steps.map { it.copy(start = round(it.start), end = round(it.end)) },
        )
        // Half the source plays for what that half played in the whole ramp.
        assertEquals(ramp.outputFraction(0.5, 1.0), tail.durationFactor * 0.5, 1e-12)
    }

    @Test
    fun cropped_isNullForAnEmptyPart() {
        assertNull(ramp.cropped(0.7, 0.7))
    }

    @Test
    fun reversed_keepsEverySpeedOnItsFrame() {
        val lopsided = SpeedRamp(
            listOf(SpeedRamp.Step(0.0, 0.3, 0.5), SpeedRamp.Step(0.3, 1.0, 2.0))
        )

        assertEquals(
            listOf(SpeedRamp.Step(0.0, 0.7, 2.0), SpeedRamp.Step(0.7, 1.0, 0.5)),
            lopsided.reversed().steps.map { it.copy(start = round(it.start), end = round(it.end)) },
        )
        assertEquals(lopsided.durationFactor, lopsided.reversed().durationFactor, 1e-12)
    }

    @Test
    fun speedProvider_reportsEachStepAndWhereTheNextOneStarts() {
        val provider = RampSpeedProvider(ramp, sourceDurationUs = 3_000_000L)

        assertEquals(2f, provider.getSpeed(0L))
        assertEquals(1_200_000L, provider.getNextSpeedChangeTimeUs(0L))
        assertEquals(0.25f, provider.getSpeed(1_200_000L))
        assertEquals(1_800_000L, provider.getNextSpeedChangeTimeUs(1_200_000L))
        assertEquals(2f, provider.getSpeed(2_999_999L))
        assertEquals(C.TIME_UNSET, provider.getNextSpeedChangeTimeUs(2_000_000L))
        // Past the clip it holds the last step.
        assertEquals(2f, provider.getSpeed(5_000_000L))
    }

    @Test
    fun speedProvider_alwaysReportsALaterChangeOnARoundedBoundary() {
        // 0.1 of 2_999_994 us is 299_999.4 us: the boundary rounds down, and
        // the time on it must already belong to the next step.
        val fine = SpeedRamp(
            listOf(
                SpeedRamp.Step(0.0, 0.1, 1.0),
                SpeedRamp.Step(0.1, 0.2, 0.5),
                SpeedRamp.Step(0.2, 1.0, 2.0),
            )
        )
        val provider = RampSpeedProvider(fine, sourceDurationUs = 2_999_994L)

        var timeUs = 0L
        val speeds = mutableListOf<Float>()
        while (timeUs != C.TIME_UNSET) {
            speeds += provider.getSpeed(timeUs)
            val next = provider.getNextSpeedChangeTimeUs(timeUs)
            if (next != C.TIME_UNSET) assert(next > timeUs)
            timeUs = next
        }
        assertEquals(listOf(1f, 0.5f, 2f), speeds)
    }

    @Test
    fun fromList_readsTheChannelStepsAndRejectsBrokenOnes() {
        val parsed = SpeedRamp.fromList(
            listOf(
                mapOf("start" to 0.0, "end" to 0.5, "speed" to 1.0),
                mapOf("start" to 0.5, "end" to 1.0, "speed" to 0.5),
            )
        )
        assertEquals(
            SpeedRamp(listOf(SpeedRamp.Step(0.0, 0.5, 1.0), SpeedRamp.Step(0.5, 1.0, 0.5))),
            parsed,
        )
        assertNull(SpeedRamp.fromList(listOf(mapOf("start" to 0.0, "end" to 1.0, "speed" to 0.0))))
        assertNull(SpeedRamp.fromList(emptyList<Any>()))
    }

    private fun round(value: Double) = Math.round(value * 1e9) / 1e9
}
