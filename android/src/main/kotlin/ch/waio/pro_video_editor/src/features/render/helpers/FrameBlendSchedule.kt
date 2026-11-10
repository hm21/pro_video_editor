package ch.waio.pro_video_editor.src.features.render.helpers

/**
 * One output frame of a frame-blended clip: the mix of the two source frames
 * around it, [weight] of the way from the earlier one to the later one.
 */
data class BlendedFrame(val presentationTimeUs: Long, val weight: Float)

/**
 * Where the output frames of a frame-blended clip fall between its source
 * frames, on the output timeline after the clip's speed change.
 *
 * The clip's output keeps the source's frame rate: a frame every [frameUs],
 * counted from the clip's first frame. On a slowed-down stretch, whose source
 * frames lie further apart, each of them mixes the source frames before and
 * after it by how far between them it falls. A stretch at the source's speed
 * or faster shows, at each grid step, the source frame nearest to it, so a
 * camera's timestamps, a little off the grid, neither drop nor repeat a frame.
 */
object FrameBlendSchedule {

    /**
     * Source frames at most this many grid steps apart play at about the
     * source's speed and are not blended: a speed of 15/16 or more. Leaves the
     * jitter of a clip's timestamps alone.
     */
    const val MAX_UNBLENDED_GAP = 16.0 / 15.0

    /**
     * Whether a stretch that moves on [sourceStepsPerFrame] source frames per
     * output frame, its speed, is blended.
     */
    fun blends(sourceStepsPerFrame: Double): Boolean =
        sourceStepsPerFrame > 0.0 && sourceStepsPerFrame * MAX_UNBLENDED_GAP < 1.0

    /**
     * A frame this close to a source frame, as a share of the way to the
     * next, shows that source frame alone. Keeps a clip at its own speed
     * from blurring by the jitter of its timestamps, and matches iOS, where a
     * frame this close may come from either side of the boundary.
     */
    const val SNAP = 1f / 32f

    /**
     * The output frames from the source frame at [previousUs] up to, but not
     * including, the one at [currentUs], on the grid of [frameUs] steps from
     * [originUs].
     *
     * Empty when the two frames fall in the same grid step, so the earlier
     * one is skipped, or when either step is not positive.
     */
    fun between(
        previousUs: Long,
        currentUs: Long,
        originUs: Long,
        frameUs: Long,
    ): List<BlendedFrame> {
        val gapUs = currentUs - previousUs
        if (gapUs <= 0 || frameUs <= 0) return emptyList()
        val blends = blends(frameUs.toDouble() / gapUs)
        val frames = mutableListOf<BlendedFrame>()
        var step = Math.floorDiv(previousUs - originUs + frameUs - 1, frameUs)
        while (true) {
            val timeUs = originUs + step * frameUs
            if (timeUs >= currentUs) break
            val weight = (timeUs - previousUs).toFloat() / gapUs
            frames += BlendedFrame(
                timeUs,
                when {
                    blends -> snapped(weight)
                    weight < 0.5f -> 0f
                    else -> 1f
                },
            )
            step++
        }
        return frames
    }

    /** [weight] with a frame within [SNAP] of a source frame on it. */
    fun snapped(weight: Float): Float = when {
        weight <= SNAP -> 0f
        weight >= 1f - SNAP -> 1f
        else -> weight
    }
}
