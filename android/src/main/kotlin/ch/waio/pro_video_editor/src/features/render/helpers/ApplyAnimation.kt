package ch.waio.pro_video_editor.src.features.render.helpers

import android.graphics.Bitmap
import android.util.Pair
import androidx.media3.common.OverlaySettings
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import ch.waio.pro_video_editor.src.features.render.models.KeyframeClock
import ch.waio.pro_video_editor.src.features.render.models.KeyframeConfig
import ch.waio.pro_video_editor.src.features.render.models.LayerAnimationConfig
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * Applies an easing function to a linear progress value (0..1).
 */
internal fun applyEasing(t: Double, curve: String): Double {
    return when (curve) {
        "easeIn" -> t * t
        "easeOut" -> t * (2 - t)
        "easeInOut" -> if (t < 0.5) 2 * t * t else -1 + (4 - 2 * t) * t
        "easeInCubic" -> t * t * t
        "easeOutCubic" -> {
            val p = 1 - t
            1 - p * p * p
        }
        "easeInOutCubic" -> if (t < 0.5) 4 * t * t * t else 1 - (-2 * t + 2).pow(3) / 2
        "bounceIn" -> 1 - applyEasing(1 - t, "bounceOut")
        "bounceOut" -> when {
            t < 1 / 2.75 -> 7.5625 * t * t
            t < 2 / 2.75 -> {
                val t2 = t - 1.5 / 2.75
                7.5625 * t2 * t2 + 0.75
            }
            t < 2.5 / 2.75 -> {
                val t2 = t - 2.25 / 2.75
                7.5625 * t2 * t2 + 0.9375
            }
            else -> {
                val t2 = t - 2.625 / 2.75
                7.5625 * t2 * t2 + 0.984375
            }
        }
        "bounceInOut" -> if (t < 0.5) {
            (1 - applyEasing(1 - 2 * t, "bounceOut")) / 2
        } else {
            (1 + applyEasing(2 * t - 1, "bounceOut")) / 2
        }
        "elasticIn" -> 1 - applyEasing(1 - t, "elasticOut")
        "elasticOut" -> {
            if (t == 0.0 || t == 1.0) t
            else 2.0.pow(-10 * t) * sin((t - 0.075) * (2 * Math.PI) / 0.3) + 1
        }
        "elasticInOut" -> if (t < 0.5) {
            (1 - applyEasing(1 - 2 * t, "elasticOut")) / 2
        } else {
            (1 + applyEasing(2 * t - 1, "elasticOut")) / 2
        }
        else -> t // "linear"
    }
}

/**
 * A layer's placement at one moment, mixed from its keyframes; see
 * [keyframePlacementAt]. [x] and [y] are the top-left corner of the unscaled
 * box in frame pixels, [rotation] is clockwise in radians.
 */
internal data class KeyframePlacement(
    val x: Double,
    val y: Double,
    val scale: Double,
    val rotation: Double,
    val opacity: Double,
)

private fun KeyframeConfig.placement() =
    KeyframePlacement(x, y, scale, rotation, opacity)

/**
 * The placement [keyframes] give a layer at [timeUs], or `null` when there are
 * none.
 *
 * [keyframes] must be sorted by time. Before the first keyframe the layer
 * holds its placement, after the last one the last one's; between two the
 * earlier one's curve eases from one to the other. An elastic or bounce curve
 * may overshoot; only the opacity is kept within 0–1 and the scale at 0 or
 * more. The rotation is mixed as it is, so a full turn stays a full turn.
 *
 * Mirrors `layerKeyframePlacementAt` in pro_image_editor, which the editor
 * preview reads.
 */
internal fun keyframePlacementAt(
    keyframes: List<KeyframeConfig>,
    timeUs: Long,
): KeyframePlacement? {
    if (keyframes.isEmpty()) return null
    val first = keyframes.first()
    if (timeUs <= first.timeUs) return first.placement()
    val last = keyframes.last()
    if (timeUs >= last.timeUs) return last.placement()

    // The last keyframe at or before [timeUs]; both ends are ruled out above,
    // so a later one always exists.
    var index = 0
    for (i in 1 until keyframes.size) {
        if (keyframes[i].timeUs > timeUs) break
        index = i
    }
    val from = keyframes[index]
    val to = keyframes[index + 1]
    val spanUs = to.timeUs - from.timeUs
    if (spanUs <= 0L) return to.placement()

    val eased = applyEasing((timeUs - from.timeUs).toDouble() / spanUs, from.curve)
    fun mix(a: Double, b: Double) = a + (b - a) * eased
    return KeyframePlacement(
        x = mix(from.x, to.x),
        y = mix(from.y, to.y),
        scale = max(0.0, mix(from.scale, to.scale)),
        rotation = mix(from.rotation, to.rotation),
        opacity = mix(from.opacity, to.opacity).coerceIn(0.0, 1.0),
    )
}

/**
 * How far an animation has brought a layer back to rest at one moment: [value]
 * is `1` at rest and `0` fully away (faded out, at the edge, tilted all the
 * way), and may overshoot either end with an elastic or bounce curve.
 *
 * [swing] is the side a wiggle tilts to: `-1` in the second half of a loop
 * cycle, `1` otherwise.
 */
internal data class AnimationProgress(val value: Double, val swing: Float = 1f)

/**
 * The progress of [anim] at [timeUs], or `null` when it does not play then.
 *
 * [startUs] and [endUs] are the range the animation counts from and towards
 * (`-1` = the start / the end of the video): an in-animation plays over the
 * first [LayerAnimationConfig.durationUs] of it and an out-animation over the
 * last. With `animateInOut` both apply and the one further from rest wins.
 *
 * A `loop` plays over the whole range, one cycle per duration counted from
 * [startUs], or only from [LayerAnimationConfig.loopStartUs] to
 * [LayerAnimationConfig.loopEndUs] when it names them, counting from the
 * first and [LayerAnimationConfig.loopPhaseUs] into a cycle there: the eased
 * value runs from rest to fully away at half a cycle and back. A wiggle runs
 * that twice per cycle, once to each side (see [AnimationProgress.swing]).
 * The cycle position is taken from the remainder of whole microseconds, so a
 * long video does not lose precision.
 */
internal fun animationProgress(
    anim: LayerAnimationConfig,
    timeUs: Long,
    startUs: Long,
    endUs: Long,
): AnimationProgress? {
    val durationUs = anim.durationUs
    if (durationUs <= 0) return null

    val effectiveStartUs = if (startUs == -1L) 0L else startUs
    val effectiveEndUs = if (endUs == -1L) Long.MAX_VALUE else endUs

    if (anim.phase == "loop") {
        if (anim.loopStartUs >= 0 && timeUs < anim.loopStartUs) return null
        if (anim.loopEndUs >= 0 && timeUs >= anim.loopEndUs) return null
        val fromUs = if (anim.loopStartUs >= 0) anim.loopStartUs else effectiveStartUs
        val elapsed = (timeUs - fromUs).coerceAtLeast(0L) + anim.loopPhaseUs
        // Floored, so a phase below zero still lands inside the cycle.
        val inCycle = elapsed.mod(durationUs)
        return if (anim.type == "wiggle") {
            // Each half of the cycle is one swing out and back.
            val inSwing = (2 * inCycle) % durationUs
            val x = abs(1.0 - 2.0 * inSwing / durationUs)
            AnimationProgress(
                applyEasing(x, anim.curve),
                if (2 * inCycle < durationUs) 1f else -1f
            )
        } else {
            val x = abs(1.0 - 2.0 * inCycle / durationUs)
            AnimationProgress(applyEasing(x, anim.curve))
        }
    }

    var inProgress: Double? = null
    var outProgress: Double? = null

    if (anim.phase == "animateIn" || anim.phase == "animateInOut") {
        val elapsed = timeUs - effectiveStartUs
        if (elapsed < durationUs) {
            inProgress = applyEasing(
                max(0.0, min(1.0, elapsed.toDouble() / durationUs)),
                anim.curve
            )
        }
    }

    if (anim.phase == "animateOut" || anim.phase == "animateInOut") {
        val remaining = effectiveEndUs - timeUs
        if (remaining < durationUs) {
            outProgress = applyEasing(
                max(0.0, min(1.0, remaining.toDouble() / durationUs)),
                anim.curve
            )
        }
    }

    // Use the minimum progress (most visible animation effect)
    val progress = when {
        inProgress != null && outProgress != null -> min(inProgress, outProgress)
        else -> inProgress ?: outProgress
    } ?: return null
    return AnimationProgress(progress)
}

/**
 * The composed look of an animated layer at one moment, before Media3 places
 * it: opacity, the slide and bounce offset in normalized device coordinates
 * ([-1, 1], +y up), the scale factor and the wiggle tilt.
 *
 * [rotationDegrees] is counter-clockwise, as Media3 turns an overlay; a
 * clockwise wiggle, like Flutter's rotation, is negative here.
 */
internal data class OverlayAnimationState(
    val alpha: Float,
    val offsetX: Float,
    val offsetY: Float,
    val scale: Float,
    val rotationDegrees: Float,
)

/**
 * Composes every animation of a layer at [timeUs]; see [animationProgress]
 * for when each one plays.
 *
 * Opacity and scale multiply, slide and bounce offsets add up and wiggle
 * angles add up. A bounce lifts the layer by a multiple of its own height
 * ([halfNormH] is half of it), a wiggle tilts it around its own center. Text
 * reveals (`typewriter`, `wordByWord`) change what the image shows, which a
 * fixed image cannot do, so they are skipped here; the caller passes one layer
 * per step instead.
 *
 * Values that an elastic or bounce curve can push out of range are clamped:
 * opacity to [0, 1] and scale to at least 0.
 */
internal fun overlayAnimationState(
    animations: List<LayerAnimationConfig>,
    timeUs: Long,
    startUs: Long,
    endUs: Long,
    baseNormX: Float,
    baseNormY: Float,
    halfNormW: Float,
    halfNormH: Float,
    layerX: Float,
    layerY: Float,
    videoWidth: Int,
    videoHeight: Int,
): OverlayAnimationState {
    var alpha = 1.0f
    var offsetX = 0f
    var offsetY = 0f
    var scale = 1f
    var rotation = 0.0

    for (anim in animations) {
        val progress = animationProgress(anim, timeUs, startUs, endUs) ?: continue
        val p = progress.value
        val invP = (1.0 - p).toFloat()

        when (anim.type) {
            "fade" -> alpha *= p.toFloat()
            "slide" -> {
                val slideFromX = anim.slideFromX
                val slideFromY = anim.slideFromY
                // A caller-chosen start point wins over the edge the
                // direction would otherwise pick.
                val off = if (slideFromX != null && slideFromY != null) {
                    slideFromOffset(
                        invP,
                        slideFromX.toFloat(), slideFromY.toFloat(),
                        layerX, layerY,
                        videoWidth, videoHeight
                    )
                } else {
                    slideOffset(
                        anim.slideDirection, invP,
                        baseNormX, baseNormY, halfNormW, halfNormH
                    )
                }
                offsetX += off.x
                offsetY += off.y
            }
            "scale" -> {
                val scaleFrom = anim.scaleFrom?.toFloat() ?: 0f
                scale *= scaleFrom + (1f - scaleFrom) * p.toFloat()
            }
            "wiggle" -> {
                val angle = anim.wiggleAngle ?: LayerAnimationConfig.DEFAULT_WIGGLE_ANGLE
                rotation += progress.swing * (1.0 - p) * angle
            }
            "bounce" -> {
                val height = anim.bounceHeight ?: LayerAnimationConfig.DEFAULT_BOUNCE_HEIGHT
                // Y counts upwards; the layer's height is twice halfNormH.
                offsetY += (invP * height * 2.0 * halfNormH).toFloat()
            }
            // "typewriter", "wordByWord": see the function's documentation.
        }
    }

    return OverlayAnimationState(
        alpha = alpha.coerceIn(0f, 1f),
        offsetX = offsetX,
        offsetY = offsetY,
        scale = scale.coerceAtLeast(0f),
        // Flutter turns clockwise, Media3 counter-clockwise.
        rotationDegrees = -Math.toDegrees(rotation).toFloat(),
    )
}

/**
 * Normalized slide offset (OpenGL coordinates, [-1, 1], +x right / +y up).
 */
internal data class SlideOffset(val x: Float, val y: Float)

/**
 * Computes the slide translation that moves a layer fully out of the canvas
 * in [direction], edge-aware rather than layer-size-relative.
 *
 * At [invP] == 1 the layer's trailing edge sits exactly on the canvas edge in
 * the slide direction (so the layer is just completely outside); at [invP] == 0
 * the offset is zero (layer at rest). The canvas spans [-1, 1] on both axes.
 *
 * @param baseNormX Layer center X in [-1, 1] (+x right).
 * @param baseNormY Layer center Y in [-1, 1] (+y up).
 * @param halfNormW Layer half-width in [-1, 1] units (imageWidth / videoWidth).
 * @param halfNormH Layer half-height in [-1, 1] units (imageHeight / videoHeight).
 */
internal fun slideOffset(
    direction: String?,
    invP: Float,
    baseNormX: Float,
    baseNormY: Float,
    halfNormW: Float,
    halfNormH: Float,
): SlideOffset = when (direction) {
    "left" -> SlideOffset(invP * (-1f - baseNormX - halfNormW), 0f) // right edge → -1
    "right" -> SlideOffset(invP * (1f - baseNormX + halfNormW), 0f) // left edge → +1
    "top" -> SlideOffset(0f, invP * (1f - baseNormY + halfNormH)) // bottom edge → +1 (Y up)
    "bottom" -> SlideOffset(0f, invP * (-1f - baseNormY - halfNormH)) // top edge → -1 (Y up)
    else -> SlideOffset(0f, 0f)
}

/**
 * Computes the slide translation toward a caller-chosen start point instead of
 * a canvas edge (see [slideOffset]).
 *
 * The start point and the layer's resting position are both top-left corners in
 * frame pixels with a top-left origin, so their difference is the distance the
 * layer travels — the layer's own size cancels out and never enters the result.
 * At [invP] == 1 the layer sits on the start point; at [invP] == 0 it rests.
 *
 * @param slideFromX Start point X in pixels from the frame's left edge.
 * @param slideFromY Start point Y in pixels from the frame's top edge.
 * @param layerX Resting X of the layer in the same coordinates.
 * @param layerY Resting Y of the layer in the same coordinates.
 */
internal fun slideFromOffset(
    invP: Float,
    slideFromX: Float,
    slideFromY: Float,
    layerX: Float,
    layerY: Float,
    videoWidth: Int,
    videoHeight: Int,
): SlideOffset {
    if (videoWidth <= 0 || videoHeight <= 0) return SlideOffset(0f, 0f)
    // The canvas spans [-1, 1] over the frame, so a pixel distance is twice its
    // fraction of the frame. Y is negated because NDC counts upwards.
    val dx = (slideFromX - layerX) / videoWidth * 2f
    val dy = -((slideFromY - layerY) / videoHeight * 2f)
    return SlideOffset(invP * dx, invP * dy)
}

/**
 * A background-frame anchor paired with an overlay-frame anchor, both in the
 * Media3 [-1, 1] range.
 */
internal data class OverlayAnchors(
    val backgroundAnchor: Float,
    val overlayAnchor: Float,
)

/**
 * Splits a desired layer-center position (in [-1, 1] NDC, possibly beyond the
 * canvas to place the layer off-screen) into the two anchors Media3 accepts.
 *
 * [androidx.media3.effect.StaticOverlaySettings.Builder] accepts only [-1, 1]
 * for both background-frame and overlay-frame anchors, so a
 * single background anchor cannot move a layer fully off-screen. The background
 * anchor covers the on-canvas part; the overlay anchor supplies the remaining
 * off-canvas shift — its ±1 range maps to ±[halfNorm] of background travel,
 * which is exactly one layer half-size, enough for an edge-flush slide-out.
 *
 * Exact only for an overlay Media3 does not turn: the overlay anchor moves it
 * along the overlay's own axes. A static layer is turned in its bitmap, so its
 * [halfNorm] is the box around the turn; an animated one is anchored on its
 * center instead (see [CenteredOverlaySettings]).
 *
 * @param targetCenter Desired layer center on this axis (may exceed [-1, 1]).
 * @param halfNorm Layer half-size on this axis in [-1, 1] units.
 */
internal fun resolveAnchor(targetCenter: Float, halfNorm: Float): OverlayAnchors {
    val background = targetCenter.coerceIn(-1f, 1f)
    val overflow = targetCenter - background
    // overlayCenter = background − overlayAnchor * halfNorm  ⇒  solve for anchor.
    val overlay = if (halfNorm > 0f) (-overflow / halfNorm).coerceIn(-1f, 1f) else 0f
    return OverlayAnchors(background, overlay)
}

/**
 * Index of the animated-image frame on screen at [presentationTimeUs].
 *
 * Playback starts [animationOffsetUs] into the animation when the layer appears
 * at [layerStartUs] (`-1` = the start of the video), so several layers can carry
 * one animation on without restarting it. The offset counts toward [loop]: it
 * wraps around a looping animation and lands on the last frame of one that
 * plays once. Before the layer appears it shows the frame it will open on.
 *
 * [frameEndsUs] is each frame's cumulative end within one playthrough, ascending;
 * its last entry is the playthrough's length.
 */
internal fun animatedFrameIndex(
    presentationTimeUs: Long,
    layerStartUs: Long,
    animationOffsetUs: Long,
    frameEndsUs: LongArray,
    loop: Boolean,
): Int {
    val totalDurationUs = frameEndsUs.lastOrNull() ?: 0L
    if (frameEndsUs.size <= 1 || totalDurationUs <= 0L) return 0

    val effectiveStartUs = if (layerStartUs == -1L) 0L else layerStartUs
    val elapsedUs = (presentationTimeUs - effectiveStartUs).coerceAtLeast(0L)
    // Folded into one playthrough before it is added, so a huge offset cannot
    // overflow the sum; the frame it lands on is the same.
    val offsetUs = animationOffsetUs.coerceAtLeast(0L).let {
        if (loop) it % totalDurationUs else it.coerceAtMost(totalDurationUs)
    }
    val t = (elapsedUs + offsetUs).let {
        if (loop) it % totalDurationUs else it.coerceAtMost(totalDurationUs - 1)
    }

    // The first end strictly greater than t identifies the active frame.
    for (i in frameEndsUs.indices) {
        if (t < frameEndsUs[i]) return i
    }
    return frameEndsUs.size - 1
}

/**
 * Where Media3 draws an overlay at one moment: [alpha], its center
 * [centerNormX] / [centerNormY] in [-1, 1] units (+y up, possibly beyond the
 * frame), the [scale] before any raster compensation and the
 * counter-clockwise [rotationDegrees].
 */
internal data class OverlayFrame(
    val alpha: Float,
    val centerNormX: Float,
    val centerNormY: Float,
    val scale: Float,
    val rotationDegrees: Float,
)

/**
 * Overlay settings that anchor an overlay's own center on [centerNormX] /
 * [centerNormY], in [-1, 1] units, even beyond the frame.
 *
 * [androidx.media3.effect.StaticOverlaySettings.Builder] rejects an anchor
 * outside [-1, 1], but Media3's overlay matrix places an overlay at any
 * anchor. Media3 scales and turns an overlay around its overlay-frame anchor,
 * so with that anchor on the overlay's center the placement stays exact
 * whatever the turn and scale. Splitting a position past the edge into a
 * clamped background anchor and an overlay anchor cannot: the overlay anchor
 * reaches at most one upright half-size, while a turned layer still shows
 * corners further out.
 */
internal class CenteredOverlaySettings(
    private val alpha: Float,
    private val centerNormX: Float,
    private val centerNormY: Float,
    private val scaleX: Float,
    private val scaleY: Float,
    private val rotation: Float,
) : OverlaySettings {
    override fun getAlphaScale(): Float = alpha
    override fun getBackgroundFrameAnchor(): Pair<Float, Float> =
        Pair(centerNormX, centerNormY)
    override fun getOverlayFrameAnchor(): Pair<Float, Float> = Pair(0f, 0f)
    override fun getScale(): Pair<Float, Float> = Pair(scaleX, scaleY)
    override fun getRotationDegrees(): Float = rotation
}

/**
 * Composes an overlay's [keyframes] and [animations] at [timeUs].
 *
 * The keyframed placement comes first: its corner, size, turn and opacity
 * replace the layer's resting ones ([baseNormX] / [baseNormY], the center in
 * [-1, 1] units, and [layerX] / [layerY], the top-left corner in frame
 * pixels). The animations play on top of it, as in the editor preview: a slide
 * starts from the edge nearest the keyframed place, and a slide and a bounce
 * measure the layer at its keyframed size. [imageWidth] x [imageHeight] is
 * the layer's unscaled box in frame pixels.
 */
internal fun overlayFrame(
    keyframes: List<KeyframeConfig>,
    keyframeClock: KeyframeClock,
    animations: List<LayerAnimationConfig>,
    timeUs: Long,
    animationStartUs: Long,
    animationEndUs: Long,
    baseNormX: Float,
    baseNormY: Float,
    imageWidth: Int,
    imageHeight: Int,
    videoWidth: Int,
    videoHeight: Int,
    layerX: Float,
    layerY: Float,
): OverlayFrame {
    val keyframe = keyframePlacementAt(keyframes, keyframeClock.keyframeTimeUs(timeUs))
    val keyframeScale = keyframe?.scale?.toFloat() ?: 1f
    val placedNormX: Float
    val placedNormY: Float
    if (keyframe != null && videoWidth > 0 && videoHeight > 0) {
        val centerX = keyframe.x.toFloat() + imageWidth / 2f
        val centerY = keyframe.y.toFloat() + imageHeight / 2f
        placedNormX = (centerX / videoWidth) * 2f - 1f
        placedNormY = 1f - (centerY / videoHeight) * 2f
    } else {
        placedNormX = baseNormX
        placedNormY = baseNormY
    }

    // Layer half-size in [-1, 1] units (canvas spans [-1, 1]), as the
    // keyframes size it.
    val halfNormW = imageWidth.toFloat() / videoWidth * keyframeScale
    val halfNormH = imageHeight.toFloat() / videoHeight * keyframeScale

    val state = overlayAnimationState(
        animations = animations,
        timeUs = timeUs,
        startUs = animationStartUs,
        endUs = animationEndUs,
        baseNormX = placedNormX,
        baseNormY = placedNormY,
        halfNormW = halfNormW,
        halfNormH = halfNormH,
        layerX = keyframe?.x?.toFloat() ?: layerX,
        layerY = keyframe?.y?.toFloat() ?: layerY,
        videoWidth = videoWidth,
        videoHeight = videoHeight,
    )

    // Anchored on its own center, even past the edge (see
    // [CenteredOverlaySettings]).
    val centerNormX = placedNormX + state.offsetX
    val centerNormY = placedNormY + state.offsetY
    // Flutter turns clockwise, Media3 counter-clockwise.
    val rotationDegrees = state.rotationDegrees -
        Math.toDegrees(keyframe?.rotation ?: 0.0).toFloat()
    val scale = state.scale * keyframeScale

    // A layer wholly off the frame draws nothing; skipping it spares the
    // compositor a draw that cannot show.
    val offFrame = liesOffFrame(
        centerNormX, centerNormY,
        halfWidthPx = imageWidth * scale / 2f,
        halfHeightPx = imageHeight * scale / 2f,
        rotationDegrees = rotationDegrees,
        videoWidth = videoWidth,
        videoHeight = videoHeight,
    )

    return OverlayFrame(
        alpha = if (offFrame) 0f else state.alpha * (keyframe?.opacity?.toFloat() ?: 1f),
        centerNormX = centerNormX,
        centerNormY = centerNormY,
        scale = scale,
        rotationDegrees = rotationDegrees,
    )
}

/**
 * Whether a layer centered on [centerNormX] / [centerNormY] ([-1, 1] units,
 * +y up), [halfWidthPx] x [halfHeightPx] frame pixels from its center to its
 * edges and turned by [rotationDegrees], lies wholly outside the frame. A
 * turned layer is measured by the box around it.
 */
internal fun liesOffFrame(
    centerNormX: Float,
    centerNormY: Float,
    halfWidthPx: Float,
    halfHeightPx: Float,
    rotationDegrees: Float,
    videoWidth: Int,
    videoHeight: Int,
): Boolean {
    if (videoWidth <= 0 || videoHeight <= 0) return false
    val radians = Math.toRadians(rotationDegrees.toDouble())
    val c = abs(cos(radians)).toFloat()
    val s = abs(sin(radians)).toFloat()
    val halfNormX = (c * halfWidthPx + s * halfHeightPx) / videoWidth * 2f
    val halfNormY = (s * halfWidthPx + c * halfHeightPx) / videoHeight * 2f
    return centerNormX - halfNormX >= 1f || centerNormX + halfNormX <= -1f ||
        centerNormY - halfNormY >= 1f || centerNormY + halfNormY <= -1f
}

/**
 * Custom BitmapOverlay that computes per-frame overlay settings for animations
 * and, for animated images (GIF), returns the correct frame for the current
 * presentation time.
 *
 * Uses [getOverlaySettings] to dynamically compute alpha, position offsets,
 * and scale based on the current presentation time and animation configs.
 *
 * [frames] holds one bitmap for a static image, or several for an animated
 * one; [frameDurationsUs] gives each frame's on-screen duration. All frames
 * must share the same dimensions ([imageWidth] x [imageHeight]).
 */
@UnstableApi
internal class AnimatedBitmapOverlay(
    private val frames: List<Bitmap>,
    private val frameDurationsUs: List<Long>,
    private val baseNormX: Float,
    private val baseNormY: Float,
    private val imageWidth: Int,
    private val imageHeight: Int,
    private val videoWidth: Int,
    private val videoHeight: Int,
    /**
     * The layer's resting top-left corner in frame pixels — what a
     * `slideFrom` start point is measured against. `0` for a stretched layer,
     * which rests on the frame origin.
     */
    private val layerX: Float,
    private val layerY: Float,
    private val layerStartUs: Long,
    private val layerEndUs: Long,
    private val loop: Boolean,
    /**
     * The range [animations] count from and towards, when it is not the
     * layer's own (`-1` = [layerStartUs] / [layerEndUs]).
     */
    private val animationStartUs: Long = -1L,
    private val animationEndUs: Long = -1L,
    /** How far into the animation playback begins; see [animatedFrameIndex]. */
    private val animationOffsetUs: Long = 0L,
    private val animations: List<LayerAnimationConfig>,
    /**
     * Undoes an overlay raster cap (see `overlayRasterScale`): the frames may be
     * rastered below the size they are laid out at, and every settings object
     * this overlay builds has to scale them back up. Per axis, because the cap
     * rounds each axis to a whole pixel on its own. `1f` when uncapped.
     */
    private val rasterScaleX: Float = 1f,
    private val rasterScaleY: Float = 1f,
    /**
     * The layer's placement over time, sorted by time; empty keeps it on
     * [baseNormX] / [baseNormY]. A keyframed layer's frames carry no rotation
     * of their own: [imageWidth] x [imageHeight] is its unrotated box, which
     * the keyframes place, turn and scale.
     */
    private val keyframes: List<KeyframeConfig> = emptyList(),
    /** The clock [keyframes] are timed on; see [KeyframeClock]. */
    private val keyframeClock: KeyframeClock = KeyframeClock.OUTPUT
) : BitmapOverlay() {

    /** Convenience constructor for a single static frame. */
    constructor(
        bitmap: Bitmap,
        baseNormX: Float,
        baseNormY: Float,
        imageWidth: Int,
        imageHeight: Int,
        videoWidth: Int,
        videoHeight: Int,
        layerX: Float,
        layerY: Float,
        layerStartUs: Long,
        layerEndUs: Long,
        animations: List<LayerAnimationConfig>,
        rasterScaleX: Float = 1f,
        rasterScaleY: Float = 1f,
        animationStartUs: Long = -1L,
        animationEndUs: Long = -1L,
        keyframes: List<KeyframeConfig> = emptyList(),
        keyframeClock: KeyframeClock = KeyframeClock.OUTPUT
    ) : this(
        frames = listOf(bitmap),
        frameDurationsUs = listOf(0L),
        baseNormX = baseNormX,
        baseNormY = baseNormY,
        imageWidth = imageWidth,
        imageHeight = imageHeight,
        videoWidth = videoWidth,
        videoHeight = videoHeight,
        layerX = layerX,
        layerY = layerY,
        layerStartUs = layerStartUs,
        layerEndUs = layerEndUs,
        loop = false,
        animationStartUs = animationStartUs,
        animationEndUs = animationEndUs,
        animations = animations,
        rasterScaleX = rasterScaleX,
        rasterScaleY = rasterScaleY,
        keyframes = keyframes,
        keyframeClock = keyframeClock
    )

    // Cumulative end time of each frame within one playthrough.
    private val frameEndsUs: LongArray = LongArray(frames.size).also { ends ->
        var acc = 0L
        for (i in frames.indices) {
            acc += frameDurationsUs[i]
            ends[i] = acc
        }
    }

    override fun getBitmap(presentationTimeUs: Long): Bitmap = frames[
        animatedFrameIndex(
            presentationTimeUs, layerStartUs, animationOffsetUs, frameEndsUs, loop
        )
    ]

    override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings {
        val frame = overlayFrame(
            keyframes = keyframes,
            keyframeClock = keyframeClock,
            animations = animations,
            timeUs = presentationTimeUs,
            animationStartUs = if (animationStartUs == -1L) layerStartUs else animationStartUs,
            animationEndUs = if (animationEndUs == -1L) layerEndUs else animationEndUs,
            baseNormX = baseNormX,
            baseNormY = baseNormY,
            imageWidth = imageWidth,
            imageHeight = imageHeight,
            videoWidth = videoWidth,
            videoHeight = videoHeight,
            layerX = layerX,
            layerY = layerY,
        )
        // Media3 turns the overlay around its own center, in pixels rather
        // than in the stretched [-1, 1] square, so the tilt keeps its shape.
        return CenteredOverlaySettings(
            alpha = frame.alpha,
            centerNormX = frame.centerNormX,
            centerNormY = frame.centerNormY,
            scaleX = rasterScaleX * frame.scale,
            scaleY = rasterScaleY * frame.scale,
            rotation = frame.rotationDegrees,
        )
    }
}
