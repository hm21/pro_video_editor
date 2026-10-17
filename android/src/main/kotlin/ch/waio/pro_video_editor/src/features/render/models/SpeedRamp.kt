package ch.waio.pro_video_editor.src.features.render.models

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * A speed that changes while a clip plays, as the Dart `VideoSpeedRamp` sends
 * it: back-to-back steps that each play one stretch of the clip at one speed.
 *
 * Positions run from 0 at the clip's first frame to 1 at its last, in the
 * order the clip plays. Dart samples its smooth curve into these steps, so the
 * render and an editor's timeline share one mapping between source and output
 * time.
 *
 * Mirrors the iOS/macOS `SpeedRamp.swift`.
 */
data class SpeedRamp(val steps: List<Step>) {

    /** One stretch of the clip at one speed. */
    data class Step(val start: Double, val end: Double, val speed: Double)

    /** How long the clip plays compared to its source. */
    val durationFactor: Double
        get() = outputFraction(0.0, 1.0)

    /**
     * How long the stretch from [from] to [to] plays, as a fraction of the
     * clip's source length.
     */
    fun outputFraction(from: Double, to: Double): Double {
        var output = 0.0
        for (step in steps) {
            val start = max(step.start, from)
            val end = min(step.end, to)
            if (end > start) output += (end - start) / step.speed
        }
        return output
    }

    /**
     * The position the clip reaches after playing [output] (a fraction of its
     * source length) from its start.
     */
    fun positionAfterOutput(output: Double): Double {
        var remaining = max(0.0, output)
        for (step in steps) {
            val stepOutput = (step.end - step.start) / step.speed
            if (remaining <= stepOutput) return step.start + remaining * step.speed
            remaining -= stepOutput
        }
        return 1.0
    }

    /**
     * The position from which the clip still plays [output] (a fraction of its
     * source length) until its end.
     */
    fun positionBeforeEndOutput(output: Double): Double {
        var remaining = max(0.0, output)
        for (step in steps.asReversed()) {
            val stepOutput = (step.end - step.start) / step.speed
            if (remaining <= stepOutput) return step.end - remaining * step.speed
            remaining -= stepOutput
        }
        return 0.0
    }

    /**
     * The part of the ramp from [from] to [to], stretched back onto 0..1: the
     * ramp of a clip trimmed to that part of itself.
     */
    fun cropped(from: Double, to: Double): SpeedRamp? {
        val width = to - from
        if (width <= 0.0) return null
        if (from <= 0.0 && to >= 1.0) return this
        val result = steps.mapNotNull { step ->
            val start = max(step.start, from)
            val end = min(step.end, to)
            if (end <= start) return@mapNotNull null
            Step(
                start = (start - from) / width,
                end = if (end >= to) 1.0 else (end - from) / width,
                speed = step.speed,
            )
        }
        return if (result.isEmpty()) null else SpeedRamp(result)
    }

    /**
     * The ramp of the clip played the other way round, so every frame keeps
     * its speed.
     */
    fun reversed(): SpeedRamp = SpeedRamp(
        steps.asReversed().map { Step(start = 1 - it.end, end = 1 - it.start, speed = it.speed) }
    )

    /** Output duration of a clip whose source lasts [sourceDurationUs]. */
    fun outputDurationUs(sourceDurationUs: Long): Long =
        (sourceDurationUs * durationFactor).roundToLong()

    /**
     * The source microseconds at the end of a clip of [sourceDurationUs] that
     * play in its last [outputUs].
     */
    fun tailSourceUs(outputUs: Long, sourceDurationUs: Long): Long {
        if (sourceDurationUs <= 0L) return 0L
        val start = positionBeforeEndOutput(outputUs.toDouble() / sourceDurationUs)
        return ((1 - start) * sourceDurationUs).roundToLong()
    }

    /**
     * The source microseconds at the start of a clip of [sourceDurationUs] that
     * play in its first [outputUs].
     */
    fun headSourceUs(outputUs: Long, sourceDurationUs: Long): Long {
        if (sourceDurationUs <= 0L) return 0L
        val end = positionAfterOutput(outputUs.toDouble() / sourceDurationUs)
        return (end * sourceDurationUs).roundToLong()
    }

    companion object {
        /**
         * Parses the steps `VideoSegment.toAsyncMap` writes under `speedRamp`;
         * null when there are none or one of them is unusable.
         */
        fun fromList(raw: Any?): SpeedRamp? {
            val list = raw as? List<*> ?: return null
            if (list.isEmpty()) return null
            val steps = list.map { item ->
                val map = item as? Map<*, *> ?: return null
                val start = (map["start"] as? Number)?.toDouble() ?: return null
                val end = (map["end"] as? Number)?.toDouble() ?: return null
                val speed = (map["speed"] as? Number)?.toDouble() ?: return null
                if (!(speed > 0.0) || speed.isInfinite() || end <= start) return null
                Step(start, end, speed)
            }
            return SpeedRamp(steps)
        }
    }
}

/** Whether the clip plays at anything other than its own speed. */
val VideoClip.changesSpeed: Boolean
    get() = speedRamp != null || playbackSpeed.let { it != null && it > 0f && it != 1.0f }

/**
 * The constant speed that plays this clip in the time it takes:
 * [VideoClip.playbackSpeed], or a speed ramp's average.
 */
fun VideoClip.averageSpeed(): Float? =
    speedRamp?.let { (1 / it.durationFactor).toFloat() } ?: playbackSpeed

/**
 * The speed the last [outputUs] of this clip play at on average, for an
 * overlap blend that takes them; [VideoClip.playbackSpeed] without a ramp.
 */
fun VideoClip.tailSpeed(outputUs: Long, sourceDurationUs: Long): Float? {
    val ramp = speedRamp ?: return playbackSpeed
    if (outputUs <= 0L) return playbackSpeed
    return (ramp.tailSourceUs(outputUs, sourceDurationUs).toDouble() / outputUs).toFloat()
}

/**
 * The speed the first [outputUs] of this clip play at on average, for an
 * overlap blend that takes them; [VideoClip.playbackSpeed] without a ramp.
 */
fun VideoClip.headSpeed(outputUs: Long, sourceDurationUs: Long): Float? {
    val ramp = speedRamp ?: return playbackSpeed
    if (outputUs <= 0L) return playbackSpeed
    return (ramp.headSourceUs(outputUs, sourceDurationUs).toDouble() / outputUs).toFloat()
}

/**
 * This clip's speed ramp for the part of its window from [fromUs] to [toUs] of
 * source, counted from its start; null without a speed ramp.
 */
fun VideoClip.croppedSpeedRamp(fromUs: Long, toUs: Long, sourceDurationUs: Long): SpeedRamp? {
    val ramp = speedRamp ?: return null
    if (sourceDurationUs <= 0L) return null
    return ramp.cropped(
        fromUs.toDouble() / sourceDurationUs,
        toUs.toDouble() / sourceDurationUs,
    )
}
