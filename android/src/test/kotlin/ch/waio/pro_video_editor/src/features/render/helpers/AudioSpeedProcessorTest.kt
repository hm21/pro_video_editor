package ch.waio.pro_video_editor.src.features.render.helpers

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
        pcm: ByteArray, speed: Float, maxFrames: Long = Long.MAX_VALUE, loop: Boolean = false
    ): ByteArray {
        val source = File.createTempFile("speed_source", ".raw")
        val output = File.createTempFile("speed_output", ".raw")
        try {
            source.writeBytes(pcm)
            AudioSpeedProcessor.stretch(source, output, sampleRate, 2, speed, maxFrames, loop)
            assertEquals(pcm.size.toLong(), source.length())
            return output.readBytes()
        } finally {
            source.delete()
            output.delete()
        }
    }

    private fun frequency(pcm: ByteArray, channel: Int): Double {
        val samples = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val from = sampleRate / 4
        val to = from + sampleRate / 2
        var crossings = 0
        for (frame in from until to) {
            if ((samples.get((frame - 1) * 2 + channel) < 0) !=
                (samples.get(frame * 2 + channel) < 0)) crossings++
        }
        assertTrue((from until to).any { abs(samples.get(it * 2 + channel).toInt()) > 1000 })
        return crossings.toDouble()
    }
}
