package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pins the limiter that replaces clipping for volumes above 1.0: material
 * under the ceiling is scaled exactly, a frame that would cross ends at the
 * ceiling, both channels share one gain, and the gain recovers afterwards.
 */
internal class PeakLimiterTest {

    private val sampleRate = 48000

    @Test
    fun `scales material that stays under the ceiling exactly`() {
        val samples = floatArrayOf(0.1f, -0.2f, 0.3f, -0.4f)

        PeakLimiter(sampleRate).process(samples, channelCount = 2, volume = 2f)

        assertEquals(listOf(0.2f, -0.4f, 0.6f, -0.8f), samples.toList())
    }

    @Test
    fun `turns a frame that would cross down to the ceiling`() {
        val samples = floatArrayOf(0.9f, -0.9f)

        PeakLimiter(sampleRate).process(samples, channelCount = 2, volume = 3f)

        assertEquals(PeakLimiter.CEILING, samples[0], 1e-6f)
        assertEquals(-PeakLimiter.CEILING, samples[1], 1e-6f)
    }

    @Test
    fun `gives both channels of a frame the same gain`() {
        val samples = floatArrayOf(0.9f, 0.1f)

        PeakLimiter(sampleRate).process(samples, channelCount = 2, volume = 3f)

        assertEquals(samples[0] / 9f, samples[1], 1e-6f)
    }

    @Test
    fun `recovers after a peak instead of staying turned down`() {
        val limiter = PeakLimiter(sampleRate)
        limiter.process(floatArrayOf(0.9f), channelCount = 1, volume = 3f)

        val quiet = FloatArray(sampleRate) { 0.1f }
        limiter.process(quiet, channelCount = 1, volume = 3f)

        assertTrue(quiet.first() < 0.3f, "still reduced right after the peak")
        assertEquals(0.3f, quiet.last(), 1e-4f)
    }

    @Test
    fun `never lets a sample past the ceiling`() {
        val samples = FloatArray(4800) { i -> if (i % 7 == 0) 1f else (i % 13) / 13f }

        PeakLimiter(sampleRate).process(samples, channelCount = 2, volume = 3f)

        assertTrue(samples.all { abs(it) <= PeakLimiter.CEILING + 1e-6f })
    }

    @Test
    fun `reset forgets a reduction in progress`() {
        val limiter = PeakLimiter(sampleRate)
        limiter.process(floatArrayOf(0.9f), channelCount = 1, volume = 3f)

        limiter.reset()

        assertEquals(1f, limiter.gain)
    }
}
