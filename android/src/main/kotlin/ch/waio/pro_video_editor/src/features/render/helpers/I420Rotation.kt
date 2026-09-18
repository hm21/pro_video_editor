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

    /** Display width × height of a coded [width]×[height] frame after [rotation]. */
    fun displaySize(width: Int, height: Int, rotation: Int): Pair<Int, Int> =
        if (normalize(rotation) % 180 == 0) width to height else height to width

    /**
     * Rotates a packed I420 [frame] of coded [width]×[height] clockwise by
     * [rotation] degrees — the container's display rotation, as
     * `MediaFormat.KEY_ROTATION` reports it. Returns [frame] itself for 0°.
     *
     * Both dimensions must be even, as every I420 frame the renderer packs is.
     */
    fun rotate(frame: ByteArray, width: Int, height: Int, rotation: Int): ByteArray {
        val steps = normalize(rotation) / 90
        if (steps == 0) return frame
        val out = ByteArray(frame.size)
        val cw = width / 2
        val ch = height / 2
        val ySize = width * height
        rotatePlane(frame, 0, out, width, height, steps)
        rotatePlane(frame, ySize, out, cw, ch, steps)
        rotatePlane(frame, ySize + cw * ch, out, cw, ch, steps)
        return out
    }

    private fun normalize(rotation: Int): Int = ((rotation % 360) + 360) % 360

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
