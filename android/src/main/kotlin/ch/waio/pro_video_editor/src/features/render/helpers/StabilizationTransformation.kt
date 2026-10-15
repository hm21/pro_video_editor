package ch.waio.pro_video_editor.src.features.render.helpers

import android.graphics.Matrix
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.MatrixTransformation
import ch.waio.pro_video_editor.src.features.render.models.StabilizationConfig
import kotlin.math.cos
import kotlin.math.sin

/**
 * Moves every frame of a clip by its stabilization keyframe.
 *
 * Media3 hands each frame over with its presentation time on the render's
 * timeline. The first frame it delivers is the clip's first frame after the
 * trim, whose source timestamp is [firstSourcePtsUs]; every later frame keeps
 * its distance from it, so source time is a fixed offset of presentation
 * time. [sourceFrameUs] is the source's frame duration, which places frames
 * the analysis skipped between their keyframes.
 *
 * The keyframe is defined in pixels with y pointing down; Media3 applies the
 * matrix in normalized device coordinates (-1..1, y up), so it is converted
 * with the frame's aspect ratio.
 */
@UnstableApi
internal class StabilizationTransformation(
    private val stabilization: StabilizationConfig,
    private val firstSourcePtsUs: Long,
    private val sourceFrameUs: Long,
) : MatrixTransformation {
    private var width = 1
    private var height = 1
    private var offsetUs: Long? = null
    private val matrix = Matrix()
    private val values = FloatArray(9)

    override fun configure(inputWidth: Int, inputHeight: Int): Size {
        width = inputWidth
        height = inputHeight
        return Size(inputWidth, inputHeight)
    }

    override fun getMatrix(presentationTimeUs: Long): Matrix {
        val offset = offsetUs ?: (firstSourcePtsUs - presentationTimeUs).also { offsetUs = it }
        val t = stabilization.transformAt(presentationTimeUs + offset, sourceFrameUs)
        val c = cos(t.rotation) * t.scale
        val s = sin(t.rotation) * t.scale
        val aspect = width.toDouble() / height
        values[Matrix.MSCALE_X] = c.toFloat()
        values[Matrix.MSKEW_X] = (s / aspect).toFloat()
        values[Matrix.MTRANS_X] = (2 * t.dx).toFloat()
        values[Matrix.MSKEW_Y] = (-s * aspect).toFloat()
        values[Matrix.MSCALE_Y] = c.toFloat()
        values[Matrix.MTRANS_Y] = (-2 * t.dy).toFloat()
        values[Matrix.MPERSP_0] = 0f
        values[Matrix.MPERSP_1] = 0f
        values[Matrix.MPERSP_2] = 1f
        matrix.setValues(values)
        return matrix
    }
}
