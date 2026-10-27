package ch.waio.pro_video_editor.src.features.render.helpers

import android.graphics.Matrix
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.MatrixTransformation
import ch.waio.pro_video_editor.src.features.render.models.KeyframeConfig
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * How a segment's keyframes move one frame: scaled by [scale] and turned
 * clockwise by [rotation] radians around the frame's center, then shifted by
 * [dx] and [dy] (fractions of its width and height), in the upright frame with
 * the origin top left.
 */
internal data class FrameMotion(
    val dx: Double,
    val dy: Double,
    val scale: Double,
    val rotation: Double,
) {
    /** Whether the frame stays exactly where it is. */
    val isIdentity: Boolean
        get() = dx == 0.0 && dy == 0.0 && scale == 1.0 && rotation == 0.0
}

/**
 * The motion a segment's [keyframes] give the frame with source timestamp
 * [sourceUs], or `null` when there are none.
 *
 * The keyframes carry the shift as `x`/`y` and are mixed as a layer's are (see
 * [keyframePlacementAt]), which is what the Dart `SegmentKeyframe` describes.
 */
internal fun segmentMotionAt(keyframes: List<KeyframeConfig>, sourceUs: Long): FrameMotion? =
    keyframePlacementAt(keyframes, sourceUs)?.let {
        FrameMotion(dx = it.x, dy = it.y, scale = it.scale, rotation = it.rotation)
    }

/**
 * A segment's [keyframes] as they apply to a reversed copy of it, whose first
 * frame is the source frame at [lastSourcePtsUs] and which counts its time
 * from 0 from there.
 *
 * Every frame keeps the motion of its source timestamp: a keyframe at `t`
 * moves to `lastSourcePtsUs - t`, and each stretch between two keyframes is
 * eased along the mirror of its curve, so it passes through the same
 * placements backwards.
 */
internal fun reversedSegmentKeyframes(
    keyframes: List<KeyframeConfig>,
    lastSourcePtsUs: Long,
): List<KeyframeConfig> {
    if (keyframes.isEmpty()) return keyframes
    val last = keyframes.size - 1
    return List(keyframes.size) { i ->
        val source = keyframes[last - i]
        // The stretch after this keyframe in the reversed clip is the one
        // before it in the source, eased by the keyframe that starts it there.
        val curve = keyframes.getOrNull(last - i - 1)?.curve?.let(::mirroredCurve) ?: "linear"
        source.copy(timeUs = lastSourcePtsUs - source.timeUs, curve = curve)
    }
}

/**
 * The curve that eases a stretch played backwards through the same values as
 * [curve] eases it forwards: `1 - curve(1 - t)`. The in and out halves swap;
 * the symmetric curves are their own mirror.
 */
internal fun mirroredCurve(curve: String): String = when (curve) {
    "easeIn" -> "easeOut"
    "easeOut" -> "easeIn"
    "easeInCubic" -> "easeOutCubic"
    "easeOutCubic" -> "easeInCubic"
    "bounceIn" -> "bounceOut"
    "bounceOut" -> "bounceIn"
    "elasticIn" -> "elasticOut"
    "elasticOut" -> "elasticIn"
    else -> curve
}

/**
 * Writes [motion] into [values] as the row-major 3×3 matrix Media3 applies in
 * normalized device coordinates (-1..1, y up) to a frame [aspect] times as
 * wide as it is high.
 */
internal fun motionNdcValues(motion: FrameMotion, aspect: Double, values: FloatArray) {
    val c = cos(motion.rotation) * motion.scale
    val s = sin(motion.rotation) * motion.scale
    values[Matrix.MSCALE_X] = c.toFloat()
    values[Matrix.MSKEW_X] = (s / aspect).toFloat()
    values[Matrix.MTRANS_X] = (2 * motion.dx).toFloat()
    values[Matrix.MSKEW_Y] = (-s * aspect).toFloat()
    values[Matrix.MSCALE_Y] = c.toFloat()
    values[Matrix.MTRANS_Y] = (-2 * motion.dy).toFloat()
    values[Matrix.MPERSP_0] = 0f
    values[Matrix.MPERSP_1] = 0f
    values[Matrix.MPERSP_2] = 1f
}

/**
 * Moves every frame of a segment by its keyframes, each by its own source
 * timestamp.
 *
 * It must come before the segment's speed change, so the presentation times
 * it is handed still run at the source's pace. The first frame it sees is the
 * segment's first frame after the trim, whose source timestamp is
 * [firstSourcePtsUs]; every later frame keeps its distance from it.
 */
@UnstableApi
internal class SegmentMotionTransformation(
    private val keyframes: List<KeyframeConfig>,
    private val firstSourcePtsUs: Long,
) : MatrixTransformation {
    private var aspect = 1.0
    private var offsetUs: Long? = null
    private val matrix = Matrix()
    private val values = FloatArray(9)

    override fun configure(inputWidth: Int, inputHeight: Int): Size {
        aspect = inputWidth.toDouble() / inputHeight
        return Size(inputWidth, inputHeight)
    }

    override fun getMatrix(presentationTimeUs: Long): Matrix {
        val offset = offsetUs ?: (firstSourcePtsUs - presentationTimeUs).also { offsetUs = it }
        val motion = segmentMotionAt(keyframes, presentationTimeUs + offset)
        if (motion == null) {
            matrix.reset()
        } else {
            motionNdcValues(motion, aspect, values)
            matrix.setValues(values)
        }
        return matrix
    }
}

/**
 * Moves packed I420 frames by a [FrameMotion] on the CPU, for the overlap
 * blends that are composed from decoded frames rather than in Media3.
 */
internal object I420Motion {
    private const val LUMA_BLACK = 16.0
    private const val CHROMA_NEUTRAL = 128.0

    /**
     * Writes [src], a [width]×[height] I420 frame, moved by [motion] into
     * [out]. What the moved picture no longer covers is black, with a soft
     * edge one plane pixel wide.
     */
    fun warp(src: ByteArray, width: Int, height: Int, motion: FrameMotion, out: ByteArray) {
        if (motion.scale <= 1e-6) {
            fillBlack(out, width, height)
            return
        }
        val cx = width / 2.0
        val cy = height / 2.0
        val shiftX = motion.dx * width
        val shiftY = motion.dy * height
        // Inverse of "scale, turn clockwise, shift": unshift, turn back, shrink.
        val cos = cos(motion.rotation) / motion.scale
        val sin = sin(motion.rotation) / motion.scale
        val cw = width / 2
        val ch = height / 2
        val planes = arrayOf(
            Triple(0, width to height, 1 to LUMA_BLACK),
            Triple(width * height, cw to ch, 2 to CHROMA_NEUTRAL),
            Triple(width * height + cw * ch, cw to ch, 2 to CHROMA_NEUTRAL),
        )
        for ((offset, size, scaleAndBlack) in planes) {
            val (planeWidth, planeHeight) = size
            val (planeScale, black) = scaleAndBlack
            val s = planeScale.toDouble()
            ClipTransitionEffects.forEachRow(planeHeight) { y ->
                val fy = (y + 0.5) * s - cy - shiftY
                val row = offset + y * planeWidth
                for (x in 0 until planeWidth) {
                    val fx = (x + 0.5) * s - cx - shiftX
                    val sx = cos * fx + sin * fy + cx
                    val sy = -sin * fx + cos * fy + cy
                    val inside = min(min(sx, width - sx), min(sy, height - sy))
                    val cover = (inside / s + 0.5).coerceIn(0.0, 1.0)
                    val v = if (cover <= 0.0) black else {
                        val picture = sample(
                            src, offset, planeWidth, planeHeight, sx / s - 0.5, sy / s - 0.5
                        )
                        black + (picture - black) * cover
                    }
                    out[row + x] = v.roundToInt().coerceIn(0, 255).toByte()
                }
            }
        }
    }

    private fun fillBlack(out: ByteArray, width: Int, height: Int) {
        val ySize = width * height
        out.fill(LUMA_BLACK.toInt().toByte(), 0, ySize)
        out.fill(CHROMA_NEUTRAL.toInt().toByte(), ySize, out.size)
    }

    /** Bilinear read of one plane at plane coordinates ([x], [y]), edges repeated. */
    private fun sample(
        src: ByteArray, offset: Int, planeWidth: Int, planeHeight: Int, x: Double, y: Double,
    ): Double {
        val maxX = planeWidth - 1
        val maxY = planeHeight - 1
        val cx = x.coerceIn(0.0, maxX.toDouble())
        val cy = y.coerceIn(0.0, maxY.toDouble())
        val x0 = cx.toInt()
        val y0 = cy.toInt()
        val x1 = if (x0 < maxX) x0 + 1 else x0
        val y1 = if (y0 < maxY) y0 + 1 else y0
        val fx = cx - x0
        val fy = cy - y0
        val row0 = offset + y0 * planeWidth
        val row1 = offset + y1 * planeWidth
        val p00 = (src[row0 + x0].toInt() and 0xFF).toDouble()
        val p01 = (src[row0 + x1].toInt() and 0xFF).toDouble()
        val p10 = (src[row1 + x0].toInt() and 0xFF).toDouble()
        val p11 = (src[row1 + x1].toInt() and 0xFF).toDouble()
        val top = p00 + (p01 - p00) * fx
        val bottom = p10 + (p11 - p10) * fx
        return top + (bottom - top) * fy
    }
}
