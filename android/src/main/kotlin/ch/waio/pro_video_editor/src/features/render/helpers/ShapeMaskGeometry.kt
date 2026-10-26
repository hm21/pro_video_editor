package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.ShapeMaskShape
import ch.waio.pro_video_editor.src.features.render.models.ShapeMaskState
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.sin

/** A rectangle in pixels of the masked image, measured from its top-left corner. */
internal data class MaskRect(val left: Double, val top: Double, val right: Double, val bottom: Double) {
    val width: Double get() = right - left
    val height: Double get() = bottom - top
}

/** A step of an outline, in pixels of the masked image, before the shape is turned. */
internal sealed class MaskPathOp {
    data class MoveTo(val x: Double, val y: Double) : MaskPathOp()
    data class LineTo(val x: Double, val y: Double) : MaskPathOp()
    data class CubicTo(
        val x1: Double, val y1: Double,
        val x2: Double, val y2: Double,
        val x: Double, val y: Double,
    ) : MaskPathOp()

    /**
     * A quarter of the ellipse in [oval], from [startDegrees] clockwise by
     * [sweepDegrees], joined to the outline so far by a straight line.
     */
    data class ArcTo(val oval: MaskRect, val startDegrees: Double, val sweepDegrees: Double) :
        MaskPathOp()

    data object Close : MaskPathOp()
}

/** The outline a shape fills, before it is turned. */
internal sealed class MaskOutline {
    data class Oval(val rect: MaskRect) : MaskOutline()
    data class RoundRect(val rect: MaskRect, val radius: Double) : MaskOutline()
    data class Ops(val ops: List<MaskPathOp>) : MaskOutline()
}

/**
 * The geometry of a shape mask on an image of a given size, exactly as the
 * `LayerMask` of pro_image_editor lays it out for the editor preview: the same
 * box, the same outlines and the same softness.
 */
internal object ShapeMaskGeometry {

    /** The Gaussian edge goes from about 10 % to 90 % over 2.56 sigma. */
    private const val FEATHER_PER_SIGMA = 2.56

    /** Skia's `SkBlurMask::ConvertRadiusToSigma`: sigma = radius * 0.57735 + 0.5. */
    private const val SKIA_SIGMA_PER_RADIUS = 0.57735
    private const val SKIA_SIGMA_OFFSET = 0.5

    /** The box the shape fills on a [width] x [height] image, not yet turned. */
    fun shapeRect(state: ShapeMaskState, width: Int, height: Int): MaskRect {
        val (cx, cy) = pivot(state, width, height)
        val halfW = state.width * width / 2
        val halfH = state.height * height / 2
        return MaskRect(cx - halfW, cy - halfH, cx + halfW, cy + halfH)
    }

    /** The point the shape is centred on and turns around, in pixels. */
    fun pivot(state: ShapeMaskState, width: Int, height: Int): Pair<Double, Double> =
        Pair(state.centerX * width, state.centerY * height)

    /** How wide the soft edge is, in pixels. */
    fun featherPx(state: ShapeMaskState, width: Int, height: Int): Double =
        state.feather * min(width, height)

    /** The standard deviation of the Gaussian edge of a soft shape, in pixels. */
    fun blurSigma(featherPx: Double): Double = featherPx / FEATHER_PER_SIGMA

    /**
     * The radius Android's `BlurMaskFilter` takes for a blur of [sigma], or 0
     * when the blur is too narrow to draw: Skia never blurs less than half a
     * pixel.
     */
    fun blurRadius(sigma: Double): Double =
        if (sigma <= SKIA_SIGMA_OFFSET) 0.0
        else (sigma - SKIA_SIGMA_OFFSET) / SKIA_SIGMA_PER_RADIUS

    /**
     * How far a linear edge reaches from its centre on either side: to the
     * farthest corner of the image, so it crosses all of it even when the
     * centre lies outside.
     */
    fun linearReach(state: ShapeMaskState, width: Int, height: Int): Double {
        val (cx, cy) = pivot(state, width, height)
        return listOf(
            hypot(cx, cy),
            hypot(width - cx, cy),
            hypot(cx, height - cy),
            hypot(width - cx, height - cy),
        ).max()
    }

    /**
     * The outline [state]'s shape fills on a [width] x [height] image, before
     * it is mirrored and turned. A [ShapeMaskShape.LINEAR] mask is an edge
     * rather than an outline and is drawn from [linearReach]; it gets its box,
     * as in pro_image_editor.
     */
    fun outline(state: ShapeMaskState, width: Int, height: Int): MaskOutline {
        val rect = shapeRect(state, width, height)
        return when (state.shape) {
            ShapeMaskShape.ELLIPSE -> MaskOutline.Oval(rect)
            ShapeMaskShape.RECTANGLE -> MaskOutline.RoundRect(
                rect,
                state.cornerRadius * min(rect.width, rect.height) / 2,
            )
            ShapeMaskShape.HEART -> MaskOutline.Ops(heart(rect))
            ShapeMaskShape.STAR -> MaskOutline.Ops(polygon(UNIT_STAR, rect))
            ShapeMaskShape.TRIANGLE -> MaskOutline.Ops(polygon(UNIT_TRIANGLE, rect))
            ShapeMaskShape.DIAMOND -> MaskOutline.Ops(polygon(UNIT_DIAMOND, rect))
            ShapeMaskShape.HEXAGON -> MaskOutline.Ops(polygon(UNIT_HEXAGON, rect))
            ShapeMaskShape.SPEECH_BUBBLE -> MaskOutline.Ops(speechBubble(rect))
            ShapeMaskShape.LINEAR -> MaskOutline.Ops(polygon(UNIT_SQUARE, rect))
        }
    }

    /**
     * The corners of a five-pointed star, a point at the top, fitted to a unit
     * box: the inner corners at a little under half the radius of the points,
     * as on the Material Design star, and the box spanning the points, of
     * which the two at the bottom stop short of the circle around the star.
     */
    val UNIT_STAR: List<Pair<Double, Double>> = run {
        val innerRadius = 0.455
        val corners = (0 until 10).map { i ->
            val angle = -PI / 2 + i * PI / 5
            val radius = if (i % 2 == 0) 1.0 else innerRadius
            Pair(cos(angle) * radius, sin(angle) * radius)
        }
        val left = corners[8].first
        val top = corners[0].second
        val right = corners[2].first
        val bottom = corners[4].second
        corners.map { (x, y) -> Pair((x - left) / (right - left), (y - top) / (bottom - top)) }
    }

    val UNIT_TRIANGLE = listOf(Pair(0.5, 0.0), Pair(1.0, 1.0), Pair(0.0, 1.0))

    val UNIT_DIAMOND = listOf(Pair(0.5, 0.0), Pair(1.0, 0.5), Pair(0.5, 1.0), Pair(0.0, 0.5))

    val UNIT_HEXAGON = listOf(
        Pair(0.5, 0.0), Pair(1.0, 0.25), Pair(1.0, 0.75),
        Pair(0.5, 1.0), Pair(0.0, 0.75), Pair(0.0, 0.25),
    )

    private val UNIT_SQUARE = listOf(Pair(0.0, 0.0), Pair(1.0, 0.0), Pair(1.0, 1.0), Pair(0.0, 1.0))

    /** [corners], in fractions of [rect], joined into a closed outline. */
    fun polygon(corners: List<Pair<Double, Double>>, rect: MaskRect): List<MaskPathOp> {
        val ops = mutableListOf<MaskPathOp>()
        corners.forEachIndexed { i, (x, y) ->
            val px = rect.left + x * rect.width
            val py = rect.top + y * rect.height
            ops += if (i == 0) MaskPathOp.MoveTo(px, py) else MaskPathOp.LineTo(px, py)
        }
        ops += MaskPathOp.Close
        return ops
    }

    /** The Material Design heart (24 dp `favorite` icon), fitted to [rect]. */
    fun heart(rect: MaskRect): List<MaskPathOp> {
        fun x(u: Double) = rect.left + u * rect.width
        fun y(v: Double) = rect.top + v * rect.height
        fun cubic(x1: Double, y1: Double, x2: Double, y2: Double, x3: Double, y3: Double) =
            MaskPathOp.CubicTo(x(x1), y(y1), x(x2), y(y2), x(x3), y(y3))
        return listOf(
            MaskPathOp.MoveTo(x(0.5), y(1.0)),
            MaskPathOp.LineTo(x(0.4275), y(0.92807)),
            cubic(0.17, 0.67357, 0.0, 0.50572, 0.0, 0.29973),
            cubic(0.0, 0.13188, 0.121, 0.0, 0.275, 0.0),
            cubic(0.362, 0.0, 0.4455, 0.04414, 0.5, 0.1139),
            cubic(0.5545, 0.04414, 0.638, 0.0, 0.725, 0.0),
            cubic(0.879, 0.0, 1.0, 0.13188, 1.0, 0.29973),
            cubic(1.0, 0.50572, 0.83, 0.67357, 0.5725, 0.92861),
            MaskPathOp.Close,
        )
    }

    /**
     * A speech bubble filling [rect]: a body with round corners over its top
     * four fifths, and below it a tail from the body's bottom edge, near its
     * left end, down to the bottom of [rect]. Built at [rect]'s own size, so
     * the corners stay round when the box is not square.
     */
    fun speechBubble(rect: MaskRect): List<MaskPathOp> {
        val w = rect.width
        val h = rect.height
        val bodyBottom = h * 0.8
        // At most a fifth of the body's width, so a corner never reaches the tail.
        val r = min(w, bodyBottom) * 0.2
        val l = rect.left
        val t = rect.top
        fun oval(left: Double, top: Double) = MaskRect(l + left, t + top, l + left + 2 * r, t + top + 2 * r)
        return listOf(
            MaskPathOp.MoveTo(l + r, t),
            MaskPathOp.LineTo(l + w - r, t),
            MaskPathOp.ArcTo(oval(w - 2 * r, 0.0), -90.0, 90.0),
            MaskPathOp.LineTo(l + w, t + bodyBottom - r),
            MaskPathOp.ArcTo(oval(w - 2 * r, bodyBottom - 2 * r), 0.0, 90.0),
            MaskPathOp.LineTo(l + w * 0.42, t + bodyBottom),
            MaskPathOp.LineTo(l + w * 0.12, t + h),
            MaskPathOp.LineTo(l + w * 0.2, t + bodyBottom),
            MaskPathOp.LineTo(l + r, t + bodyBottom),
            MaskPathOp.ArcTo(oval(0.0, bodyBottom - 2 * r), 90.0, 90.0),
            MaskPathOp.LineTo(l, t + r),
            MaskPathOp.ArcTo(oval(0.0, 0.0), 180.0, 90.0),
            MaskPathOp.Close,
        )
    }
}
