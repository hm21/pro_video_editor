package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.math.roundToLong

/**
 * Pure geometry for **overlap** clip transitions (dissolve / slide / push /
 * wipe) that honors each clip's playback speed.
 *
 * The requested transition duration is interpreted in **output** (post-speed)
 * time, matching the non-transition timeline. Each side of the blend therefore
 * consumes `outputDuration * speed` microseconds of its own source, so the
 * footage inside the blend plays at the requested speed just like the rest of
 * the clip.
 *
 * Kept free of any Android/Media3 types so it can be unit-tested on the JVM and
 * shared by both the pre-render gate and the renderer wiring. The Darwin
 * pipeline mirrors this logic in `ClipTransitionGeometry.swift`.
 */
internal object ClipTransitionGeometry {

    /**
     * Resolved overlap geometry for a single clip boundary.
     *
     * @property outputDurationUs Output (post-speed) duration of the blended
     *  transition clip — the value the blended clip is inserted with.
     * @property outgoingTailSourceUs Source microseconds consumed from the
     *  outgoing clip's tail (`outputDurationUs * outgoingSpeed`).
     * @property incomingHeadSourceUs Source microseconds consumed from the
     *  incoming clip's head (`outputDurationUs * incomingSpeed`).
     */
    data class OverlapPlan(
        val outputDurationUs: Long,
        val outgoingTailSourceUs: Long,
        val incomingHeadSourceUs: Long,
    )

    /**
     * Computes the overlap geometry for the boundary between an outgoing and an
     * incoming clip, or `null` when the transition cannot be rendered (caller
     * should fall back to a hard cut).
     *
     * Returns `null` when either clip would be fully consumed by the blend
     * (no body left), preserving the 1× behavior where a transition needs some
     * non-blended content on both sides.
     *
     * @param outgoingSourceDurationUs Trimmed source duration of the outgoing clip.
     * @param incomingSourceDurationUs Trimmed source duration of the incoming clip.
     * @param transitionDurationUs Requested transition duration in output time.
     * @param outgoingSpeed Outgoing clip playback speed (null/<=0 → 1×).
     * @param incomingSpeed Incoming clip playback speed (null/<=0 → 1×).
     */
    fun planOverlap(
        outgoingSourceDurationUs: Long,
        incomingSourceDurationUs: Long,
        transitionDurationUs: Long,
        outgoingSpeed: Float?,
        incomingSpeed: Float?,
    ): OverlapPlan? {
        if (outgoingSourceDurationUs <= 0L || incomingSourceDurationUs <= 0L) return null

        val sOut = validSpeedOrOne(outgoingSpeed)
        val sIn = validSpeedOrOne(incomingSpeed)

        // Full output durations of each clip after its own speed.
        val outgoingOutputDur = outgoingSourceDurationUs / sOut
        val incomingOutputDur = incomingSourceDurationUs / sIn

        // Clamp the requested (output-time) duration to what each side can give.
        val dOut = minOf(transitionDurationUs.toDouble(), outgoingOutputDur, incomingOutputDur)
        if (dOut <= 0.0) return null

        val outputDurationUs = dOut.roundToLong()
        val tailSourceUs = (dOut * sOut).roundToLong()
        val headSourceUs = (dOut * sIn).roundToLong()

        // Both sides must keep some non-blended body, matching the 1× behavior.
        if (outputDurationUs <= 0L ||
            outgoingSourceDurationUs - tailSourceUs <= 0L ||
            incomingSourceDurationUs - headSourceUs <= 0L
        ) {
            return null
        }

        return OverlapPlan(
            outputDurationUs = outputDurationUs,
            outgoingTailSourceUs = tailSourceUs,
            incomingHeadSourceUs = headSourceUs,
        )
    }

    /**
     * Number of OUTPUT frames the blended clip should emit so the decoded
     * outgoing tail ([decodedTailFrames] frames covering [tailSourceDurationUs]
     * of source) is replayed across [outputDurationUs] of output. When the
     * output is shorter than the source span the tail is sped up (fewer frames);
     * when longer it is slowed down (frames duplicated). Falls back to
     * [decodedTailFrames] (1×) for non-positive inputs.
     *
     * Android-only: the Media3 transition renderer blends frame-by-frame, so it
     * must pick the output frame count explicitly. The Darwin renderer applies
     * speed via AVFoundation `scaleTimeRange` and does not need this.
     */
    fun outputFrameCount(
        decodedTailFrames: Int,
        tailSourceDurationUs: Long,
        outputDurationUs: Long,
    ): Int {
        if (outputDurationUs <= 0L || tailSourceDurationUs <= 0L) {
            return decodedTailFrames.coerceAtLeast(1)
        }
        return ((decodedTailFrames.toLong() * outputDurationUs) / tailSourceDurationUs)
            .toInt().coerceAtLeast(1)
    }

    private fun validSpeedOrOne(speed: Float?): Double =
        if (speed != null && speed > 0f) speed.toDouble() else 1.0
}
