package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.SpeedRamp
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

internal class AudioSpeedProcessorTest {
    private val sampleRate = 16000

    @Test
    fun speedChangesDurationAndKeepsPitchAndStereo() {
        for (speed in listOf(0.25f, 0.5f, 2f, 3f)) {
            val pcm = tone(seconds = 3, oppositePhase = false)
            val output = stretch(pcm, speed)
            val frames = output.size / 4
            assertTrue(abs(frames - sampleRate * 3 / speed) <= 2, "duration at $speed")
            assertTrue(abs(frequency(output, 0) - 440) < 5, "left pitch at $speed")
            assertTrue(abs(frequency(output, 1) - 660) < 5, "right pitch at $speed")
        }
    }

    @Test
    fun oppositePhaseStereoStaysAudibleAndInPhaseRelationship() {
        val output = stretch(tone(seconds = 3, oppositePhase = true), 0.5f)
        val samples = ByteBuffer.wrap(output).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        for (frame in 0 until samples.limit() / 2) {
            assertTrue(abs(samples.get(frame * 2) + samples.get(frame * 2 + 1)) <= 1)
        }
        assertTrue(abs(frequency(output, 0) - 440) < 5, "pitch of cancelling stereo")
    }

    @Test
    fun soundStartsOnTheFirstSampleAndEndsAtFullLevel() {
        for (speed in listOf(0.5f, 0.8f, 1.25f, 2f, 3f)) {
            val pcm = periodicTone(seconds = 2)
            val output = stretch(pcm, speed)
            assertTrue(pcm.copyOf(400).contentEquals(output.copyOf(400)), "start at $speed")
            assertQuietestPeriodAbove(output, 0.95, "once at $speed")
        }
    }

    @Test
    fun loopStretchesEachSeamWithoutAGap() {
        for (speed in listOf(0.5f, 0.8f, 1.25f, 2f, 3f)) {
            val output = stretch(
                periodicTone(seconds = 1), speed, maxFrames = sampleRate * 5L, loop = true
            )
            assertEquals(sampleRate * 5 * 4, output.size, "body length at $speed")
            assertQuietestPeriodAbove(output, 0.95, "loop at $speed")
        }
    }

    @Test
    fun rampFollowsItsStepsAtUnchangedPitch() {
        // The first half plays at 2x and the second at 0.5x: the switch from
        // 400 Hz to 600 Hz at 2 s of source moves to 1 s, and 4 s last 5 s.
        val output = stretch(twoTones(), 1f, ramp = fastThenSlow)
        assertTrue(abs(output.size / 4 - sampleRate * 5) <= 2, "duration")
        assertTrue(abs(frequency(output, 0, from = 0.1, to = 0.9) - 400) < 5, "fast part")
        assertTrue(abs(frequency(output, 0, from = 1.1, to = 4.9) - 600) < 5, "slow part")
        assertTrue(abs(frequency(output, 1, from = 1.1, to = 4.9) - 600) < 5, "right channel")
    }

    @Test
    fun loopPlaysTheWholeRampOnEachPassWithoutAGap() {
        val output = stretch(
            periodicTone(seconds = 1), 1f, maxFrames = sampleRate * 5L, loop = true,
            ramp = fastThenSlow
        )
        assertEquals(sampleRate * 5 * 4, output.size, "body length")
        assertQuietestPeriodAbove(output, 0.95, "looped ramp")
    }

    @Test
    fun normalSpeedCopiesTheExactPcm() {
        val input = tone(seconds = 1, oppositePhase = false)
        assertTrue(input.contentEquals(stretch(input, 1f)))
    }

    private fun tone(seconds: Int, oppositePhase: Boolean): ByteArray {
        val pcm = ByteBuffer.allocate(sampleRate * seconds * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (frame in 0 until sampleRate * seconds) {
            val left = (12000 * sin(2 * PI * 440 * frame / sampleRate)).toInt().toShort()
            val right = if (oppositePhase) (-left).toShort()
                else (6000 * sin(2 * PI * 660 * frame / sampleRate)).toInt().toShort()
            pcm.putShort(left).putShort(right)
        }
        return pcm.array()
    }

    private val fastThenSlow = SpeedRamp(
        listOf(SpeedRamp.Step(0.0, 0.5, 2.0), SpeedRamp.Step(0.5, 1.0, 0.5))
    )

    /** Two seconds of 400 Hz, then two of 600 Hz, on both channels. */
    private fun twoTones(): ByteArray {
        val pcm = ByteBuffer.allocate(sampleRate * 4 * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (frame in 0 until sampleRate * 4) {
            val hz = if (frame < sampleRate * 2) 400 else 600
            val value = (12000 * sin(2 * PI * hz * frame / sampleRate)).roundToInt().toShort()
            pcm.putShort(value).putShort(value)
        }
        return pcm.array()
    }

    /** A 400 Hz tone of whole periods, so the source loops without a jump. */
    private fun periodicTone(seconds: Int): ByteArray {
        val pcm = ByteBuffer.allocate(sampleRate * seconds * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (frame in 0 until sampleRate * seconds) {
            val value = (12000 * sin(2 * PI * 400 * frame / sampleRate)).roundToInt().toShort()
            pcm.putShort(value).putShort(value)
        }
        return pcm.array()
    }

    /** Fails when any whole 400 Hz period peaks below [share] of the tone. */
    private fun assertQuietestPeriodAbove(pcm: ByteArray, share: Double, message: String) {
        val samples = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val period = sampleRate / 400
        for (start in 0 until samples.limit() / 2 - period + 1 step period) {
            val peak = (start until start + period).maxOf { abs(samples.get(it * 2).toInt()) }
            assertTrue(peak >= 12000 * share, "$message: peak $peak at frame $start")
        }
    }

    private fun stretch(
        pcm: ByteArray, speed: Float, maxFrames: Long = Long.MAX_VALUE, loop: Boolean = false,
        ramp: SpeedRamp? = null
    ): ByteArray {
        val source = File.createTempFile("speed_source", ".raw")
        val output = File.createTempFile("speed_output", ".raw")
        try {
            source.writeBytes(pcm)
            AudioSpeedProcessor.stretch(source, output, sampleRate, 2, speed, maxFrames, loop, ramp)
            assertEquals(pcm.size.toLong(), source.length())
            return output.readBytes()
        } finally {
            source.delete()
            output.delete()
        }
    }

    /** The tone's frequency between [from] and [to] seconds, by zero crossings. */
    private fun frequency(
        pcm: ByteArray, channel: Int, from: Double = 0.25, to: Double = 0.75
    ): Double {
        val samples = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val first = (sampleRate * from).roundToInt()
        val last = (sampleRate * to).roundToInt()
        var crossings = 0
        for (frame in first until last) {
            if ((samples.get((frame - 1) * 2 + channel) < 0) !=
                (samples.get(frame * 2 + channel) < 0)) crossings++
        }
        assertTrue((first until last).any { abs(samples.get(it * 2 + channel).toInt()) > 1000 })
        return crossings / (2 * (to - from))
    }
}
