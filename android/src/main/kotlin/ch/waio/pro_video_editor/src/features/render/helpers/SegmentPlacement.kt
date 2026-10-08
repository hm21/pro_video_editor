package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.KeyframeClock
import ch.waio.pro_video_editor.src.features.render.models.KeyframeConfig
import ch.waio.pro_video_editor.src.features.render.models.SegmentTransformConfig
import kotlin.math.max
import kotlin.math.min

/** A rectangle in canvas pixels, top-left origin. */
internal data class SegmentRect(val x: Double, val y: Double, val w: Double, val h: Double)

/**
 * Where a composition clip is drawn on the canvas. [draw] is the (possibly
 * oversized for `cover`) destination rectangle; [clip] is the target box the
 * draw is cut to so overflow can't bleed onto other layers. [clip] is `null`
 * when the clip fills the whole canvas (no clipping needed). [rotation] is the
 * clockwise turn of the whole placed box around its own centre, in radians —
 * [draw] and [clip] stay the unrotated rectangles.
 */
internal data class SegmentPlacement(
    val draw: SegmentRect,
    val clip: SegmentRect?,
    val rotation: Double = 0.0
)

/**
 * Resolves the destination rectangle (canvas pixels, top-left origin) for a
 * clip of [displayW] x [displayH] given its transform, together with the box it
 * is clipped to. A `null` transform fills the canvas (no clipping).
 */
internal fun segmentPlacement(
    cfg: SegmentTransformConfig?,
    displayW: Int,
    displayH: Int,
    canvasW: Int,
    canvasH: Int
): SegmentPlacement {
    if (cfg == null) {
        return SegmentPlacement(
            SegmentRect(0.0, 0.0, canvasW.toDouble(), canvasH.toDouble()),
            clip = null
        )
    }
    val dW = displayW.toDouble().coerceAtLeast(1.0)
    val dH = displayH.toDouble().coerceAtLeast(1.0)
    val boxX = cfg.offsetX ?: 0.0
    val boxY = cfg.offsetY ?: 0.0
    val boxW = cfg.width ?: dW
    val boxH = cfg.height ?: dH
    val box = SegmentRect(boxX, boxY, boxW, boxH)
    val draw = when (cfg.fit) {
        "contain" -> {
            val s = min(boxW / dW, boxH / dH)
            val w = dW * s
            val h = dH * s
            SegmentRect(boxX + (boxW - w) / 2, boxY + (boxH - h) / 2, w, h)
        }
        "cover" -> {
            val s = max(boxW / dW, boxH / dH)
            val w = dW * s
            val h = dH * s
            SegmentRect(boxX + (boxW - w) / 2, boxY + (boxH - h) / 2, w, h)
        }
        else -> box // "fill"
    }
    return SegmentPlacement(draw, box, cfg.rotation)
}

/**
 * [cfg] as [keyframe] places it: the keyframe's corner replaces the box's
 * top-left corner, its scale grows or shrinks the box around its center and
 * its rotation replaces the box's. The fit stays.
 *
 * A `null` transform is the whole canvas, filled, which keyframes may move off
 * it; a box without a size is the clip's own [displayW] x [displayH].
 */
internal fun keyframedSegmentTransform(
    cfg: SegmentTransformConfig?,
    keyframe: KeyframePlacement,
    displayW: Int,
    displayH: Int,
    canvasW: Int,
    canvasH: Int
): SegmentTransformConfig {
    val boxW = cfg?.width ?: if (cfg == null) canvasW.toDouble() else displayW.toDouble()
    val boxH = cfg?.height ?: if (cfg == null) canvasH.toDouble() else displayH.toDouble()
    val w = boxW * keyframe.scale
    val h = boxH * keyframe.scale
    return SegmentTransformConfig(
        offsetX = keyframe.x + (boxW - w) / 2,
        offsetY = keyframe.y + (boxH - h) / 2,
        width = w,
        height = h,
        fit = cfg?.fit ?: "fill",
        rotation = keyframe.rotation
    )
}

/**
 * Places a composition clip by its layer's keyframes, frame by frame.
 *
 * [clipStartUs] is where the clip's first frame lies on the composition
 * timeline the keyframes are measured on. Media3 hands each clip's effects
 * frames on a timeline of its own, so the shader measures every frame from the
 * first one it draws and adds that to [clipStartUs] (see [compositionTimeUs]).
 */
internal class SegmentKeyframeAnimator(
    private val keyframes: List<KeyframeConfig>,
    /** The clock [keyframes] are timed on; see [KeyframeClock]. */
    private val keyframeClock: KeyframeClock,
    private val transform: SegmentTransformConfig?,
    private val displayW: Int,
    private val displayH: Int,
    private val canvasW: Int,
    private val canvasH: Int,
    val clipStartUs: Long
) {
    /**
     * The composition time of a frame at [presentationTimeUs], when the clip's
     * first frame came at [firstPresentationTimeUs].
     */
    fun compositionTimeUs(presentationTimeUs: Long, firstPresentationTimeUs: Long): Long =
        clipStartUs + (presentationTimeUs - firstPresentationTimeUs).coerceAtLeast(0L)

    /**
     * The clip's placement and opacity at [compositionTimeUs], or the plain
     * transform at full opacity when there are no keyframes.
     */
    fun at(compositionTimeUs: Long): Pair<SegmentPlacement, Float> {
        val keyframe = keyframePlacementAt(
            keyframes,
            keyframeClock.keyframeTimeUs(compositionTimeUs)
        )
            ?: return Pair(
                segmentPlacement(transform, displayW, displayH, canvasW, canvasH),
                1f
            )
        val moved = keyframedSegmentTransform(
            transform, keyframe, displayW, displayH, canvasW, canvasH
        )
        return Pair(
            segmentPlacement(moved, displayW, displayH, canvasW, canvasH),
            keyframe.opacity.toFloat()
        )
    }
}
