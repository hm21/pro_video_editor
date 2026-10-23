package ch.waio.pro_video_editor.src.features.render.models

/**
 * A volume that changes over time on the exported video, moving in a
 * straight line from one point to the next — the Dart `AudioVolumeCurve`.
 *
 * Before the first point the volume stays at the first point's, and after
 * the last one at the last point's.
 *
 * @property timesUs When each point sits on the exported video, sorted.
 * @property volumes The volume of each point, from 0 to 1.
 */
class VolumeCurve(
    val timesUs: LongArray,
    val volumes: DoubleArray
) {
    init {
        require(timesUs.size == volumes.size) { "Every point needs a volume" }
        require(timesUs.isNotEmpty()) { "A volume curve needs a point" }
    }

    /** The volume at [timeUs], exactly as the Dart `volumeAt` computes it. */
    fun volumeAt(timeUs: Double): Double {
        if (timeUs <= timesUs.first()) return volumes.first()
        if (timeUs >= timesUs.last()) return volumes.last()
        var low = 0
        var high = timesUs.size - 1
        while (high - low > 1) {
            val middle = (low + high) ushr 1
            if (timesUs[middle] <= timeUs) low = middle else high = middle
        }
        val span = (timesUs[high] - timesUs[low]).toDouble()
        if (span <= 0.0) return volumes[high]
        val t = (timeUs - timesUs[low]) / span
        return volumes[low] + (volumes[high] - volumes[low]) * t
    }

    /**
     * The stretches of time, in µs, where the volume is below 1, merged and
     * sorted; unbounded ends are [Long.MIN_VALUE] and [Long.MAX_VALUE].
     * Everything outside them is left as it is.
     */
    fun loweredRangesUs(): List<LongRange> {
        val ranges = mutableListOf<LongRange>()
        fun add(from: Long, to: Long) {
            val last = ranges.lastOrNull()
            if (last != null && from <= last.last) {
                ranges[ranges.size - 1] = last.first..maxOf(last.last, to)
            } else {
                ranges.add(from..to)
            }
        }
        if (volumes.first() < 1.0) add(Long.MIN_VALUE, timesUs.first())
        for (i in 0 until timesUs.size - 1) {
            if (volumes[i] < 1.0 || volumes[i + 1] < 1.0) add(timesUs[i], timesUs[i + 1])
        }
        if (volumes.last() < 1.0) add(timesUs.last(), Long.MAX_VALUE)
        return ranges
    }

    companion object {
        /**
         * Parses the `volumeCurve` entry of an audio track: interleaved
         * `[time in µs, volume, …]` from a Dart `Float64List`, or a plain list
         * of numbers. Null when there is no curve or no complete point. A
         * volume that is not a number leaves the audio unchanged.
         */
        fun fromChannel(value: Any?): VolumeCurve? {
            val raw = when (value) {
                is DoubleArray -> value
                is FloatArray -> DoubleArray(value.size) { value[it].toDouble() }
                is List<*> -> DoubleArray(value.size) {
                    (value[it] as? Number)?.toDouble() ?: 0.0
                }
                else -> return null
            }
            val count = raw.size / 2
            if (count == 0) return null
            return VolumeCurve(
                timesUs = LongArray(count) { raw[it * 2].toLong() },
                volumes = DoubleArray(count) {
                    val volume = raw[it * 2 + 1]
                    if (volume.isNaN()) 1.0 else volume.coerceIn(0.0, 1.0)
                }
            )
        }
    }
}
