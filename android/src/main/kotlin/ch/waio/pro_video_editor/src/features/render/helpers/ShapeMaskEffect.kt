package ch.waio.pro_video_editor.src.features.render.helpers

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import ch.waio.pro_video_editor.src.features.render.models.KeyframeClock
import ch.waio.pro_video_editor.src.features.render.models.ShapeMaskConfig

/**
 * Shapes every frame of one composition clip with a [ShapeMaskConfig]: each
 * pixel keeps its own alpha times the mask's there, as [MaskEffect] does with
 * a still matte.
 *
 * The mask is drawn over the whole frame, the clip's own upright frame before
 * it is placed, by a [ShapeMaskPainter] — on the first frame, and again
 * whenever its keyframes change it. Media3 hands each clip's effects frames on
 * a timeline of its own, so every frame is measured from the first one drawn
 * and added to [clipStartUs], where that one lies on the composition timeline
 * the keyframes are measured on, as [SegmentKeyframeAnimator] does.
 *
 * @param mask The mask.
 * @param keyframeClock The clock the mask's keyframes are timed on.
 * @param clipStartUs Where the clip's first frame lies on the composition
 *  timeline.
 */
@UnstableApi
internal class ShapeMaskEffect(
    private val mask: ShapeMaskConfig,
    private val keyframeClock: KeyframeClock,
    private val clipStartUs: Long,
) : GlEffect {

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
        if (useHdr) {
            // An ES 2.0 SDR program, like the still mask. RenderVideo
            // pre-transcodes HDR sources whenever a layer has a mask.
            throw VideoFrameProcessingException("A layer shape mask does not support HDR input")
        }
        return ShapeMaskShaderProgram(mask, keyframeClock, clipStartUs)
    }

    @UnstableApi
    private class ShapeMaskShaderProgram(
        private val mask: ShapeMaskConfig,
        private val keyframeClock: KeyframeClock,
        private val clipStartUs: Long,
    ) : BaseGlShaderProgram(
        /* useHighPrecisionColorComponents= */ false, /* texturePoolCapacity= */ 1
    ) {

        private val glProgram: GlProgram = try {
            GlProgram(VERTEX_SHADER_SOURCE, FRAGMENT_SHADER_SOURCE)
        } catch (e: Exception) {
            throw VideoFrameProcessingException(e)
        }

        private var painter: ShapeMaskPainter? = null
        private var matteTexId: Int = -1
        private var frameWidth = 0
        private var frameHeight = 0

        /** The presentation time of the first frame drawn; see [ShapeMaskEffect]. */
        private var firstPresentationTimeUs = Long.MIN_VALUE

        companion object {
            private const val VERTEX_SHADER_SOURCE =
                "attribute vec4 aFramePosition;\n" +
                "attribute vec4 aTexSamplingCoord;\n" +
                "varying vec2 vTexSamplingCoord;\n" +
                "void main() {\n" +
                "  gl_Position = aFramePosition;\n" +
                "  vTexSamplingCoord = aTexSamplingCoord.xy;\n" +
                "}"

            // As in MaskEffect: highp where the GPU has it, and t flipped,
            // since the mask's first row is uploaded at t = 0.
            private const val FRAGMENT_SHADER_SOURCE =
                "#ifdef GL_FRAGMENT_PRECISION_HIGH\n" +
                "precision highp float;\n" +
                "#else\n" +
                "precision mediump float;\n" +
                "#endif\n" +
                "uniform sampler2D uTexSampler;\n" +
                "uniform sampler2D uMaskSampler;\n" +
                "varying vec2 vTexSamplingCoord;\n" +
                "void main() {\n" +
                "  vec4 src = texture2D(uTexSampler, vTexSamplingCoord);\n" +
                "  vec2 matteCoord = vec2(vTexSamplingCoord.x," +
                " 1.0 - vTexSamplingCoord.y);\n" +
                "  float matte = texture2D(uMaskSampler, matteCoord).a;\n" +
                "  gl_FragColor = vec4(src.rgb, src.a * matte);\n" +
                "}"
        }

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            frameWidth = inputWidth
            frameHeight = inputHeight
            return Size(inputWidth, inputHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            try {
                glProgram.use()

                if (firstPresentationTimeUs == Long.MIN_VALUE) {
                    firstPresentationTimeUs = presentationTimeUs
                }
                val compositionTimeUs =
                    clipStartUs + (presentationTimeUs - firstPresentationTimeUs).coerceAtLeast(0L)
                val state = mask.stateAt(keyframeClock.keyframeTimeUs(compositionTimeUs))

                val painter = painter ?: createPainter().also { painter = it }
                if (painter.paint(state) || matteTexId == -1) {
                    if (matteTexId == -1) {
                        matteTexId = GlUtil.createTexture(painter.bitmap)
                    } else {
                        GlUtil.setTexture(matteTexId, painter.bitmap)
                    }
                }

                glProgram.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
                glProgram.setSamplerTexIdUniform("uMaskSampler", matteTexId, 1)

                val vertexData = GlUtil.getNormalizedCoordinateBounds()
                glProgram.setBufferAttribute(
                    "aFramePosition", vertexData, if (vertexData.size == 8) 2 else 4
                )
                val texData = GlUtil.getTextureCoordinateBounds()
                glProgram.setBufferAttribute(
                    "aTexSamplingCoord", texData, if (texData.size == 8) 2 else 4
                )

                glProgram.bindAttributesAndUniforms()
                // No glClear and no blending, as in MaskEffect.
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                GlUtil.checkGlError()
            } catch (e: VideoFrameProcessingException) {
                throw e
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e, presentationTimeUs)
            }
        }

        /**
         * A painter as large as the frame, held within the GPU's largest
         * texture: the mask is a fraction of the frame however many pixels it
         * is drawn at.
         */
        private fun createPainter(): ShapeMaskPainter {
            val value = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, value, 0)
            val limit = if (value[0] > 0) value[0] else 2048
            val width = frameWidth.coerceIn(1, limit)
            val height = frameHeight.coerceIn(1, limit)
            return ShapeMaskPainter(width, height)
        }

        override fun release() {
            super.release()
            try {
                if (matteTexId != -1) {
                    GlUtil.deleteTexture(matteTexId)
                    matteTexId = -1
                }
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e)
            } finally {
                painter?.recycle()
                painter = null
                try {
                    glProgram.delete()
                } catch (e: Exception) {
                    throw VideoFrameProcessingException(e)
                }
            }
        }
    }
}
