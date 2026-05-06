package ch.waio.pro_video_editor.src.features.render.helpers

import android.content.Context
import android.opengl.GLES20
import android.opengl.Matrix
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram

/**
 * A GlEffect that handles positioning and scaling of a video segment
 * within a larger render canvas.
 *
 * It converts pixel-based offsets and sizes from the Flutter side into
 * the normalized OpenGL coordinates used by Media3 effects.
 */
@UnstableApi
class VideoCompositionTransformation(
    private val x: Double?,
    private val y: Double?,
    private val width: Double?,
    private val height: Double?,
    private val videoWidth: Int,
    private val videoHeight: Int,
    private val renderWidth: Int,
    private val renderHeight: Int
) : GlEffect {

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
        return VideoCompositionShaderProgram(context, useHdr, this)
    }

    @UnstableApi
    private class VideoCompositionShaderProgram(
        context: Context,
        useHdr: Boolean,
        private val effect: VideoCompositionTransformation
    ) : BaseGlShaderProgram(useHdr, /* texturePoolCapacity= */ 1) {

        private val glProgram: GlProgram

        companion object {
            private const val VERTEX_SHADER_SOURCE =
                "attribute vec4 aFramePosition;\n" +
                "attribute vec4 aTexSamplingCoord;\n" +
                "varying vec2 vTexSamplingCoord;\n" +
                "uniform mat4 uTransformationMatrix;\n" +
                "void main() {\n" +
                "  gl_Position = uTransformationMatrix * aFramePosition;\n" +
                "  vTexSamplingCoord = aTexSamplingCoord.xy;\n" +
                "}"

            private const val FRAGMENT_SHADER_SOURCE =
                "precision mediump float;\n" +
                "uniform sampler2D uTexSampler;\n" +
                "varying vec2 vTexSamplingCoord;\n" +
                "void main() {\n" +
                "  gl_FragColor = texture2D(uTexSampler, vTexSamplingCoord);\n" +
                "}"
        }

        init {
            try {
                glProgram = GlProgram(VERTEX_SHADER_SOURCE, FRAGMENT_SHADER_SOURCE)
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e)
            }
        }

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            return Size(effect.renderWidth, effect.renderHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            try {
                glProgram.use()
                
                // Clear the target framebuffer to transparent before drawing the segment.
                // This ensures that segments that don't cover the full canvas don't show garbage.
                GLES20.glClearColor(0f, 0f, 0f, 0f)
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                
                // Enable alpha blending to support transparent layers and overlays.
                GLES20.glEnable(GLES20.GL_BLEND)
                GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)

                val glMatrix = FloatArray(16)
                Matrix.setIdentityM(glMatrix, 0)

                val targetWidth = (effect.width ?: effect.videoWidth.toDouble()).toFloat()
                val targetHeight = (effect.height ?: effect.videoHeight.toDouble()).toFloat()
                
                // sx and sy are half-widths in NDC (relative to a 2.0 wide NDC space)
                val sx = if (effect.renderWidth > 0) targetWidth / effect.renderWidth else 1.0f
                val sy = if (effect.renderHeight > 0) targetHeight / effect.renderHeight else 1.0f

                // Convert pixel (x, y) to NDC top-left
                val leftNDC = if (effect.renderWidth > 0) (2f * (effect.x ?: 0.0).toFloat() / effect.renderWidth) - 1f else -1.0f
                val topNDC = if (effect.renderHeight > 0) 1f - (2f * (effect.y ?: 0.0).toFloat() / effect.renderHeight) else 1.0f

                // Target center in NDC for a quad that is 2x2 centered at 0,0
                val centerX = leftNDC + sx
                val centerY = topNDC - sy

                Matrix.translateM(glMatrix, 0, centerX, centerY, 0f)
                Matrix.scaleM(glMatrix, 0, sx, sy, 1f)

                glProgram.setFloatsUniform("uTransformationMatrix", glMatrix)
                glProgram.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
                
                // Set attribute buffers with robust size detection
                val vertexData = GlUtil.getNormalizedCoordinateBounds()
                val vertexSize = if (vertexData.size == 8) 2 else 4
                glProgram.setBufferAttribute("aFramePosition", vertexData, vertexSize)

                val texData = GlUtil.getTextureCoordinateBounds()
                val texSize = if (texData.size == 8) 2 else 4
                glProgram.setBufferAttribute("aTexSamplingCoord", texData, texSize)
                
                glProgram.bindAttributesAndUniforms()
                
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                
                GLES20.glDisable(GLES20.GL_BLEND)
                GlUtil.checkGlError()
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e, presentationTimeUs)
            }
        }
    }
}
