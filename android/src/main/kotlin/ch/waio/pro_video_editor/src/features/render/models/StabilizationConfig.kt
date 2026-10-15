package ch.waio.pro_video_editor.src.features.render.models

/**
 * Per-frame transforms that steady a clip, keyed by source timestamp.
 *
 * Mirrors the Dart `VideoStabilization`: for each keyframe, the frame is
 * scaled by `scale` and turned clockwise by `rotation` (radians) around its
 * center, then shifted by `dx`/`dy` (fractions of its width/height), in the
 * upright frame with the origin top left.
 */
class StabilizationConfig(
    private val timesUs: LongArray,
    private val values: DoubleArray,
) {
    /** One interpolated keyframe. */
    data class Transform(
        val dx: Double,
        val dy: Double,
        val rotation: Double,
        val scale: Double,
    )

    /**
     * Keyframes further apart than this were not analyzed frame by frame (a
     * `maxFrameRate` cap); the frames between them are interpolated.
     */
    private val frameGapLimitUs: Long = timesUs.toList().zipWithNext { a, b -> b - a }
        .sorted().let { gaps -> if (gaps.isEmpty()) 0L else gaps[gaps.size / 2] * 3 / 2 }

    /**
     * The transform for the picture on screen at [sourceUs].
     *
     * That picture is the last frame that started at or before [sourceUs], so
     * its own keyframe applies; only across a gap the analysis skipped is the
     * transform interpolated. Before the first and after the last keyframe the
     * nearest one holds.
     */
    fun transformAt(sourceUs: Long): Transform {
        // A millisecond of slack absorbs rounding in the frame clock.
        val probe = sourceUs + 1_000
        val found = timesUs.binarySearch(probe)
        val index = if (found >= 0) found else -found - 2
        if (index < 0) return keyframe(0)
        if (index >= timesUs.size - 1) return keyframe(timesUs.size - 1)
        val t0 = timesUs[index]
        val t1 = timesUs[index + 1]
        if (t1 - t0 <= frameGapLimitUs) return keyframe(index)
        val k = ((sourceUs - t0).toDouble() / (t1 - t0)).coerceIn(0.0, 1.0)
        val a = keyframe(index)
        val b = keyframe(index + 1)
        return Transform(
            dx = a.dx + k * (b.dx - a.dx),
            dy = a.dy + k * (b.dy - a.dy),
            rotation = a.rotation + k * (b.rotation - a.rotation),
            scale = a.scale + k * (b.scale - a.scale),
        )
    }

    private fun keyframe(i: Int) = Transform(
        dx = values[4 * i],
        dy = values[4 * i + 1],
        rotation = values[4 * i + 2],
        scale = values[4 * i + 3],
    )

    companion object {
        /** Parses the map written by the Dart `VideoStabilization.toMap`. */
        fun fromMap(map: Map<*, *>?): StabilizationConfig? {
            if (map == null) return null
            val times = (map["timesUs"] as? List<*>)?.map { (it as Number).toLong() }
                ?: return null
            val values = (map["values"] as? List<*>)?.map { (it as Number).toDouble() }
                ?: return null
            if (times.isEmpty() || values.size < times.size * 4) return null
            return StabilizationConfig(times.toLongArray(), values.toDoubleArray())
        }
    }
}
