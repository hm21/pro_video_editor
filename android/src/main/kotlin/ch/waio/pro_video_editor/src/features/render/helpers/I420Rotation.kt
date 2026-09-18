package ch.waio.pro_video_editor.src.features.render.helpers

/**
 * Rotates packed I420 frames from their coded orientation into the
 * orientation they are displayed at.
 *
 * A decoder hands out frames as they are stored, and a clip's container
 * rotation is not applied to them. A phone recording is typically stored
 * landscape with a 90°/270° rotation flag, while a transcoded or downloaded
 * clip of the same picture is stored upright with none. Blending the two as
 * they come off the decoder compares 1920×1080 against 1080×1920, so
 * [ClipTransitionRenderer] rotates each side through here first and blends
 * in display space.
 *
 * Kept free of Android types so it can be unit-tested on the JVM.
 */
internal object I420Rotation {

    /**
     * The whole clockwise quarter turns [rotation] degrees amount to (0..3).
     * Negative and overflowing angles wrap; anything between two quarter
     * turns rounds down, so [displaySize] and [rotate] always agree.
     */
    fun quarterTurns(rotation: Int): Int = (((rotation % 360) + 360) % 360) / 90

    /** Display width × height of a coded [width]×[height] frame after [rotation]. */
    fun displaySize(width: Int, height: Int, rotation: Int): Pair<Int, Int> =
        if (quarterTurns(rotation) % 2 == 0) width to height else height to width

    /**
     * Rotates a packed I420 [frame] of coded [width]×[height] clockwise by
     * [rotation] degrees — the container's display rotation, as
     * `MediaFormat.KEY_ROTATION` reports it — into [dst] and returns it.
     * [dst] must hold at least [frame]'s size and, for a real turn, be a
     * separate array; the caller keeps one per segment so the decode loop
     * does not allocate per frame. A 0° rotation copies [frame] into [dst].
     *
     * Chroma is handled with the same truncating half-size as the packing
     * side, so an odd dimension stays consistent with how it was packed.
     */
    fun rotate(
        frame: ByteArray, width: Int, height: Int, rotation: Int,
        dst: ByteArray = ByteArray(frame.size),
    ): ByteArray {
        val steps = quarterTurns(rotation)
        if (steps == 0) {
            if (dst !== frame) frame.copyInto(dst)
            return dst
        }
        require(dst !== frame) { "a quarter turn cannot run in place" }
        val cw = width / 2
        val ch = height / 2
        val ySize = width * height
        rotatePlane(frame, 0, dst, width, height, steps)
        rotatePlane(frame, ySize, dst, cw, ch, steps)
        rotatePlane(frame, ySize + cw * ch, dst, cw, ch, steps)
        return dst
    }

    /**
     * Rotates one [w]×[h] plane at [offset] of [src] into the same offset of
     * [dst]; a quarter turn writes an [h]×[w] plane there.
     */
    private fun rotatePlane(
        src: ByteArray, offset: Int, dst: ByteArray, w: Int, h: Int, steps: Int,
    ) {
        var o = offset
        when (steps) {
            // 90° clockwise: the source's left column becomes the top row.
            1 -> for (y in 0 until w) {
                for (x in 0 until h) dst[o++] = src[offset + (h - 1 - x) * w + y]
            }
            // 180°: the plane read back to front.
            2 -> {
                var i = offset + w * h - 1
                repeat(w * h) { dst[o++] = src[i--] }
            }
            // 270° clockwise: the source's right column becomes the top row.
            3 -> for (y in 0 until w) {
                for (x in 0 until h) dst[o++] = src[offset + x * w + (w - 1 - y)]
            }
        }
    }
}
