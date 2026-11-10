package ch.waio.pro_video_editor.src.features.render.helpers

/**
 * The images an animated overlay shows, read one frame at a time.
 */
internal interface OverlayFrames<T> {
    /** How many frames there are. */
    val count: Int

    /**
     * The image of frame [index]. It stays valid until a different frame is
     * asked for, which may free it.
     */
    fun frameAt(index: Int): T
}

/** Frames decoded up front: the frames of an animated GIF, or one still image. */
internal class DecodedFrames<T>(private val frames: List<T>) : OverlayFrames<T> {
    override val count: Int get() = frames.size

    override fun frameAt(index: Int): T = frames[index]
}

/**
 * A frame sequence decoded as each frame comes on screen, holding one decoded
 * frame at a time.
 *
 * Decoding every frame up front held all of them at once. A drawing that draws
 * itself over six seconds exports as about 175 images of up to 8 MB each at
 * 1080p, so the render needed a gigabyte or more before it started. A render
 * asks for the frames in order, so each one is decoded once per playthrough:
 * once for a sequence that does not loop, again on every pass of one that does.
 *
 * [first] is frame 0, already decoded. [decode] decodes frame `index`, or
 * returns `null` when it does not decode; the frame shown before it then stays
 * on screen until the next one. [release] frees a frame that is no longer
 * shown.
 */
internal class OnDemandFrames<T : Any>(
    override val count: Int,
    first: T,
    private val decode: (index: Int) -> T?,
    private val release: (T) -> Unit,
) : OverlayFrames<T> {
    private var shownIndex = 0
    private var shown: T = first

    override fun frameAt(index: Int): T {
        if (index == shownIndex) return shown
        // Set first, so a frame that does not decode is not retried on every
        // video frame it covers.
        shownIndex = index
        val next = decode(index) ?: return shown
        release(shown)
        shown = next
        return next
    }
}
