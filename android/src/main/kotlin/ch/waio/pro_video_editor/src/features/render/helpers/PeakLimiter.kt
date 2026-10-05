package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.math.abs
import kotlin.math.exp

/**
 * Keeps an amplified signal under full scale by turning it down where it
 * would cross [CEILING], instead of clipping it there.
 *
 * A volume above 1.0 pushes material that is already near full scale — a
 * mastered song, a loud recording — past it. Clipping those samples is
 * audible as distortion; this lowers the gain for the frames that would
 * cross, instantly, and lets it recover over [RELEASE_SECONDS] so the
 * reduction follows the music rather than every sample.
 *
 * All channels of a frame share one gain, so a peak in one channel does not
 * shift the stereo image. There is no lookahead: the output never runs late
 * against the video, and a frame that crosses still comes out at exactly the
 * ceiling. Material that stays under the ceiling passes untouched.
 *
 * @param sampleRate Frames per second of the signal.
 */
class PeakLimiter(sampleRate: Int) {

    private val releaseCoefficient =
        exp(-1.0 / (RELEASE_SECONDS * sampleRate.coerceAtLeast(1))).toFloat()

    /** The gain the limiter currently applies, 1 when it is not limiting. */
    var gain = 1f
        private set

    /**
     * The gain to apply to a frame whose loudest sample, after the volume,
     * is [peak] — at most `CEILING / peak`, so the frame ends at or under
     * the ceiling.
     */
    fun gainFor(peak: Float): Float {
        val target = if (peak > CEILING) CEILING / peak else 1f
        gain = if (target < gain) {
            target
        } else {
            target + (gain - target) * releaseCoefficient
        }
        return gain
    }

    /**
     * Applies [volume] to the interleaved [samples] of [channelCount]
     * channels in place, limiting every frame that would cross the ceiling.
     */
    fun process(samples: FloatArray, channelCount: Int, volume: Float) {
        val channels = channelCount.coerceAtLeast(1)
        var frame = 0
        while (frame + channels <= samples.size) {
            var peak = 0f
            for (c in 0 until channels) {
                peak = maxOf(peak, abs(samples[frame + c] * volume))
            }
            val frameGain = volume * gainFor(peak)
            for (c in 0 until channels) {
                samples[frame + c] *= frameGain
            }
            frame += channels
        }
    }

    /** Forgets any reduction in progress, e.g. after a seek. */
    fun reset() {
        gain = 1f
    }

    companion object {
        /**
         * The highest level a limited frame reaches: -1 dBFS. AAC overshoots a
         * limited peak by a few percent (measured 4 % on a sine at 300 %), so a
         * ceiling closer to full scale clips again in the encoder.
         */
        const val CEILING = 0.891251f

        /** How long the gain takes to recover by ~63 % after a peak. */
        const val RELEASE_SECONDS = 0.05
    }
}
