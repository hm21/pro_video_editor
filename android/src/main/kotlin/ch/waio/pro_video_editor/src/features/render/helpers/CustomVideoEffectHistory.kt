package ch.waio.pro_video_editor.src.features.render.helpers

/**
 * Which earlier frames of a clip a custom video effect keeps, and which of
 * them it hands over for a frame.
 *
 * Only the bookkeeping: each kept frame is a time and the id of the slot its
 * pixels were copied to. The GL side owns the slots.
 *
 * For each offset the effect asks for, a frame gets the newest kept frame at
 * least that far back. Real timestamps are not exact multiples of the frame
 * duration (a 30 fps stream alternates 33333 and 33334 µs), so a frame up to
 * [toleranceUs] short of the offset still counts; otherwise "three frames
 * back" would turn into four every third frame.
 */
internal class CustomVideoEffectHistory(
    offsetsUs: LongArray,
    private val toleranceUs: Long = TOLERANCE_US,
    private val capacity: Int = MAX_FRAMES,
) {
    /** A kept frame: its time and the slot holding its pixels. */
    data class Entry(val timeUs: Long, val slot: Int)

    private val offsets = offsetsUs.copyOf()
    private val entries = ArrayList<Entry>()

    /** How far back the effect looks at most, in microseconds. */
    val maxOffsetUs: Long = offsets.maxOrNull()?.coerceAtLeast(0L) ?: 0L

    /** Whether the effect asks for earlier frames at all. */
    val isUsed: Boolean = offsets.isNotEmpty()

    /** The number of frames kept now. */
    val size: Int get() = entries.size

    /** For each offset, the frame the frame at [timeUs] gets, or null. */
    fun lookup(timeUs: Long): List<Entry?> =
        offsets.map { offset -> newestAtOrBefore(timeUs - offset + toleranceUs) }

    /**
     * Keeps the frame at [timeUs], stored in [slot], and returns the slots of
     * frames no later frame can ask for.
     *
     * A time that goes backwards starts the history over.
     */
    fun record(timeUs: Long, slot: Int): List<Int> {
        val freed = ArrayList<Int>()
        if (entries.isNotEmpty() && timeUs < entries.last().timeUs) {
            entries.mapTo(freed) { it.slot }
            entries.clear()
        }
        entries += Entry(timeUs, slot)

        // A later frame looks back to just after this limit at most, so the
        // newest frame at or before it is the oldest one still needed.
        val limit = timeUs - maxOffsetUs + toleranceUs
        val oldestNeeded = entries.indexOfLast { it.timeUs <= limit }
        if (oldestNeeded > 0) {
            repeat(oldestNeeded) { freed += entries.removeAt(0).slot }
        }
        while (entries.size > capacity) {
            freed += entries.removeAt(0).slot
        }
        return freed
    }

    /** Forgets every frame, as a new clip starts, and returns their slots. */
    fun clear(): List<Int> {
        val freed = entries.map { it.slot }
        entries.clear()
        return freed
    }

    private fun newestAtOrBefore(limitUs: Long): Entry? {
        for (i in entries.indices.reversed()) {
            if (entries[i].timeUs <= limitUs) return entries[i]
        }
        return null
    }

    companion object {
        /** How far short of an offset a frame may lie and still count, in µs. */
        const val TOLERANCE_US = 1_000L

        /**
         * The most frames kept, whatever the offsets: two seconds of 120 fps
         * video, so a broken timestamp cannot pile up frames without bound.
         */
        const val MAX_FRAMES = 240
    }
}
