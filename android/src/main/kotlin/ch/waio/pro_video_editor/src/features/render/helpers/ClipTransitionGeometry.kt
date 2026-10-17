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
     * A blend may consume a clip **entirely** (no non-blended body left): the
     * caller drops the fully-consumed side and keeps the blend clip in its
     * place, so two adjacent transitions can each fill their shared clip. Only a
     * non-positive blend, a rounding overrun, or invalid inputs return `null`.
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

        // A clip may be fully consumed by the blend (body == 0); the caller
        // drops it and keeps the blend in its place. Reject only a non-positive
        // blend or a rounding overrun that would consume more than a clip has.
        if (outputDurationUs <= 0L ||
            outgoingSourceDurationUs - tailSourceUs < 0L ||
            incomingSourceDurationUs - headSourceUs < 0L
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
     * Resolves the overlap geometry for a **seamless loop wrap** where the
     * outgoing tail and incoming head are carved from the *same* single clip
     * (its whole start-to-end range).
     *
     * Unlike [planOverlap] the two sides share one source, so the head
     * `[0, head)` and tail `[L - tail, L)` must not overlap — a positive middle
     * body must remain (`head + tail < sourceDuration`). Because both sides are
     * the same clip they also share its playback [speed], so `head == tail`.
     * Returns `null` when no body would remain (caller falls back to no wrap).
     *
     * Multi-clip loops (last clip ≠ first clip) use [planOverlap] instead, since
     * each side then keeps its own independent source.
     *
     * @param sourceDurationUs Trimmed source duration of the single looping clip.
     * @param transitionDurationUs Requested wrap duration in output time.
     * @param speed The clip's playback speed (null/<=0 → 1×).
     */
    fun planWrap(
        sourceDurationUs: Long,
        transitionDurationUs: Long,
        speed: Float?,
    ): OverlapPlan? {
        if (sourceDurationUs <= 0L) return null
        val s = validSpeedOrOne(speed)
        val outputDur = sourceDurationUs / s
        // Both sides consume `dOut * speed` of the same source; head + tail must
        // leave a positive middle body, so dOut is capped just below outputDur/2.
        val dOut = minOf(transitionDurationUs.toDouble(), outputDur / 2.0)
        if (dOut <= 0.0) return null
        val outputDurationUs = dOut.roundToLong()
        val sideSourceUs = (dOut * s).roundToLong()
        if (outputDurationUs <= 0L || sourceDurationUs - 2L * sideSourceUs <= 0L) return null
        return OverlapPlan(
            outputDurationUs = outputDurationUs,
            outgoingTailSourceUs = sideSourceUs,
            incomingHeadSourceUs = sideSourceUs,
        )
    }

    /**
     * [planWrap] for a clip whose head and tail play at different speeds, as
     * under a speed ramp: [tailSpeed] and [headSpeed] are the average speeds of
     * the stretches a blend of [transitionDurationUs] takes from either end,
     * which the caller has already capped at half the clip's output.
     *
     * Returns null when no body would remain between head and tail.
     */
    fun planWrap(
        sourceDurationUs: Long,
        transitionDurationUs: Long,
        tailSpeed: Float?,
        headSpeed: Float?,
    ): OverlapPlan? {
        if (sourceDurationUs <= 0L || transitionDurationUs <= 0L) return null
        val tailSourceUs = (transitionDurationUs * validSpeedOrOne(tailSpeed)).roundToLong()
        val headSourceUs = (transitionDurationUs * validSpeedOrOne(headSpeed)).roundToLong()
        if (sourceDurationUs - tailSourceUs - headSourceUs <= 0L) return null
        return OverlapPlan(
            outputDurationUs = transitionDurationUs,
            outgoingTailSourceUs = tailSourceUs,
            incomingHeadSourceUs = headSourceUs,
        )
    }

    /**
     * One clip as the overlap pre-render lays it out.
     *
     * @property sourceDurationUs Trimmed source duration of the clip.
     * @property speed Clip playback speed (null/<=0 → 1×).
     * @property blendDurationUs Requested duration of the overlap blend into the
     *  next clip, or null when this clip does not blend into it.
     */
    data class TimelineClip(
        val sourceDurationUs: Long,
        val speed: Float?,
        val blendDurationUs: Long?,
    )

    /**
     * Which overlap blends start at or after [endUs], where the render ends on
     * the clips' timeline (see [clipTimelineEndUs]). Such a blend never reaches
     * the output, so it need not be rendered.
     *
     * Lays the clips out the way the pre-render rewrites them: every blend takes
     * its tail from the outgoing clip and its head from the incoming one, so
     * each transition shortens the timeline by one blend. A clip whose blend
     * cannot be planned is a hard cut, as in [planOverlap].
     *
     * The layout assumes every earlier blend renders. One that fails becomes a
     * hard cut, which only pushes later clips back, so a blend found past the
     * end stays past it.
     *
     * @param startOffsetUs Where the first clip starts. A loop wrap moves the
     *  first clip's head to the end, which pulls every blend earlier by up to
     *  the wrap's requested duration, so the caller passes that negated.
     * @return per clip, whether its blend into the next clip starts at or after
     *  [endUs]; false for a clip without a blend, and for all when [endUs] is
     *  null.
     */
    fun blendsPastEnd(
        clips: List<TimelineClip>,
        endUs: Long?,
        startOffsetUs: Long = 0L,
    ): BooleanArray {
        val result = BooleanArray(clips.size)
        if (endUs == null) return result
        var positionUs = startOffsetUs
        // Source the previous blend took from the head of the current clip.
        var headTakenUs = 0L
        for ((i, clip) in clips.withIndex()) {
            val durationUs = clip.sourceDurationUs - headTakenUs
            headTakenUs = 0L
            val next = clips.getOrNull(i + 1)
            val plan = if (clip.blendDurationUs != null && next != null) {
                planOverlap(
                    outgoingSourceDurationUs = durationUs,
                    incomingSourceDurationUs = next.sourceDurationUs,
                    transitionDurationUs = clip.blendDurationUs,
                    outgoingSpeed = clip.speed,
                    incomingSpeed = next.speed,
                )
            } else null
            if (plan == null) {
                positionUs += outputDurationUs(durationUs, clip.speed)
                continue
            }
            val blendStartUs = positionUs +
                    outputDurationUs(durationUs - plan.outgoingTailSourceUs, clip.speed)
            result[i] = blendStartUs >= endUs
            positionUs = blendStartUs + plan.outputDurationUs
            headTakenUs = plan.incomingHeadSourceUs
        }
        return result
    }

    /**
     * Maps the render's end, given on the output timeline after the
     * composition-wide [globalSpeed], onto the clips' own timeline, where each
     * clip runs at its own speed only. Null stays null (no end).
     */
    fun clipTimelineEndUs(globalEndUs: Long?, globalSpeed: Float?): Long? =
        globalEndUs?.let { (it * validSpeedOrOne(globalSpeed)).roundToLong() }

    /** Output duration of [sourceDurationUs] of a clip played at [speed]. */
    fun outputDurationUs(sourceDurationUs: Long, speed: Float?): Long =
        (sourceDurationUs / validSpeedOrOne(speed)).roundToLong()

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
