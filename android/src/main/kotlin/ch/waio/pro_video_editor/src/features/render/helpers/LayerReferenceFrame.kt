package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The frame a single-track render's image layers are laid out in, and how a
 * clip of another size converts into it.
 *
 * iOS and macOS scale every clip to fit one render size
 * (`CompositionBuilder.calculateTransform`) and draw the layers onto the
 * scaled clip, from its own top-left corner: the compositor drops the
 * centring offset, so no layer is shifted for a clip of another shape.
 * Android draws the layers per clip, on the clip's own frame, before a
 * `Presentation` scales the clip to the output. With clips of one resolution
 * the two agree. With mixed resolutions the same pixel offsets land on a
 * differently sized frame on Android: on a clip two thirds the size, a layer
 * sat 1.5x further from the origin and covered 1.5x more of the frame, and
 * one in the lower third fell out of it.
 *
 * So a layer is converted into each clip's own pixels first, by the factor
 * that clip is scaled by to fit the composition frame.
 */
internal object LayerReferenceFrame {

    /**
     * The composition frame for clips of the given (rotated) sizes, or `null`
     * when none of them has a usable size.
     *
     * Mirrors how the Apple `VideoSequenceBuilder` picks its render size: the
     * first clip's size, replaced by every later clip that is wider or taller
     * than the current one. A clip whose size could not be read is skipped
     * rather than letting a zero axis win.
     *
     * The rule does not care which axis is which, so it holds whether or not
     * the sizes already include a user rotation, as long as every clip's does.
     */
    fun of(clipSizes: List<Pair<Int, Int>>): Pair<Int, Int>? {
        var frame: Pair<Int, Int>? = null
        for ((width, height) in clipSizes) {
            if (width <= 0 || height <= 0) continue
            val current = frame
            if (current == null || width > current.first || height > current.second) {
                frame = Pair(width, height)
            }
        }
        return frame
    }

    /**
     * Clip pixels per composition-frame pixel for a [clipWidth] x [clipHeight]
     * clip scaled to fit [frame], as iOS and macOS fit it.
     *
     * `1.0` when the clip has the frame's size, and whenever either size is
     * unknown, so such a clip keeps the layers exactly as it received them.
     */
    fun layoutScale(clipWidth: Int, clipHeight: Int, frame: Pair<Int, Int>?): Double {
        if (frame == null) return 1.0
        val (frameWidth, frameHeight) = frame
        if (clipWidth <= 0 || clipHeight <= 0 || frameWidth <= 0 || frameHeight <= 0) {
            return 1.0
        }
        // The clip is fitted by the axis that binds first, min(frame / clip);
        // its reciprocal is the larger clip / frame ratio.
        return max(
            clipWidth.toDouble() / frameWidth,
            clipHeight.toDouble() / frameHeight,
        )
    }
}

/**
 * This layer with every pixel value multiplied by [scale]: its offset, its
 * explicit size, its natural size when it has none, and a slide animation's
 * start point.
 *
 * A stretched layer (no offset) fills whatever frame it lands on, so only its
 * decode size changes. Rotation, timing and the slide edges are relative and
 * stay as they are. At a [scale] of `1.0` the layer itself is returned.
 */
internal fun VideoSequenceBuilder.ImageLayerConfig.scaledToClipFrame(
    scale: Double,
): VideoSequenceBuilder.ImageLayerConfig {
    if (scale == 1.0) return this
    return copy(
        x = x?.let { (it * scale).roundToInt() },
        y = y?.let { (it * scale).roundToInt() },
        width = width?.times(scale),
        height = height?.times(scale),
        naturalSizeScale = naturalSizeScale * scale,
        animations = animations.map { animation ->
            if (animation.slideFromX == null && animation.slideFromY == null) {
                animation
            } else {
                animation.copy(
                    slideFromX = animation.slideFromX?.times(scale),
                    slideFromY = animation.slideFromY?.times(scale),
                )
            }
        },
    )
}
