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
import kotlin.math.roundToInt

/**
 * A GlEffect that handles positioning and scaling of a video segment
 * within a larger render canvas.
 *
 * It converts pixel-based offsets and sizes from the Flutter side into
 * the normalized OpenGL coordinates used by Media3 effects. The output frame is
 * the full canvas size; the video is drawn into the target rectangle and the
 * rest stays transparent, so the default Media3 compositor can alpha-blend the
 * layers on top of each other.
 *
 * The draw itself does **not** blend — see the note in `drawFrame`. Partial
 * alpha (a chroma-keyed edge, an [androidx.media3.effect.AlphaScale]d layer)
 * passes through unchanged and is blended once, by the Media3 compositor.
 *
 * When a clip box ([clipX], [clipY], [clipWidth], [clipHeight]) is provided, the
 * draw is scissored to that box (canvas pixels, top-left origin). This clips
 * `cover` overflow so a scaled-up clip cannot bleed past its target rectangle
 * onto other layers. When the clip box is `null`, no scissor is applied.
 *
 * [rotation] turns the placed box clockwise around its own centre (radians,
 * Flutter's `Transform.rotate` convention). The clip box turns with it, so a
 * rotated clip is still cut at the box edge — which `glScissor` cannot express,
 * being axis-aligned. A rotated draw therefore clips in the fragment shader, in
 * the quad's own unrotated space, instead of scissoring. The scissor is kept
 * for the unrotated case so nothing about the existing path changes.
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
    private val renderHeight: Int,
    private val clipX: Double? = null,
    private val clipY: Double? = null,
    private val clipWidth: Double? = null,
    private val clipHeight: Double? = null,
    private val rotation: Double = 0.0
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
                "varying vec2 vQuadCoord;\n" +
                "uniform mat4 uTransformationMatrix;\n" +
                "void main() {\n" +
                "  gl_Position = uTransformationMatrix * aFramePosition;\n" +
                "  vTexSamplingCoord = aTexSamplingCoord.xy;\n" +
                "  vQuadCoord = aFramePosition.xy;\n" +
                "}"

            // uClipHalf is the clip box's half-extent in the quad's own
            // [-1, 1] space. The draw and clip rectangles are concentric, so
            // the box is simply a centred sub-rectangle of the quad — and
            // because this space is pre-rotation, the test stays correct once
            // the vertex matrix turns the quad. 1.0 (the default) clips
            // nothing.
            private const val FRAGMENT_SHADER_SOURCE =
                "precision mediump float;\n" +
                "uniform sampler2D uTexSampler;\n" +
                "uniform vec2 uClipHalf;\n" +
                "varying vec2 vTexSamplingCoord;\n" +
                "varying vec2 vQuadCoord;\n" +
                "void main() {\n" +
                "  if (abs(vQuadCoord.x) > uClipHalf.x ||\n" +
                "      abs(vQuadCoord.y) > uClipHalf.y) {\n" +
                "    discard;\n" +
                "  }\n" +
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

                // Clear the target framebuffer to transparent before drawing the
                // segment, so segments that don't cover the full canvas don't
                // show garbage.
                GLES20.glClearColor(0f, 0f, 0f, 0f)
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

                // No blending: this draw replaces. The target was just cleared
                // to (0,0,0,0) and exactly one quad is drawn, so there is
                // nothing to blend against — and GL_SRC_ALPHA/
                // GL_ONE_MINUS_SRC_ALPHA against a transparent destination
                // *squares* the alpha (dst.a = a*a + 0*(1-a)). That was
                // harmless while this shader only ever saw opaque input, but a
                // chroma-keyed layer arrives with a soft, partially transparent
                // edge, which blending here would darken and thin out.
                //
                // The one real blend is Media3's own DefaultCompositorGlProgram,
                // which uses glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA,
                // ONE, ONE_MINUS_SRC_ALPHA) — correct straight-alpha source-over.

                val targetWidth = (effect.width ?: effect.videoWidth.toDouble()).toFloat()
                val targetHeight = (effect.height ?: effect.videoHeight.toDouble()).toFloat()

                // Placement (and the turn, when there is one) is pure geometry;
                // see [SegmentPlacementMatrix], which is unit-tested on the JVM.
                val glMatrix = SegmentPlacementMatrix.build(
                    x = (effect.x ?: 0.0).toFloat(),
                    y = (effect.y ?: 0.0).toFloat(),
                    targetWidth = targetWidth,
                    targetHeight = targetHeight,
                    renderWidth = effect.renderWidth,
                    renderHeight = effect.renderHeight,
                    rotation = effect.rotation
                )

                glProgram.setFloatsUniform("uTransformationMatrix", glMatrix)
                glProgram.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)

                // Clip the draw to the target box so `cover` overflow (a scaled
                // up clip larger than its rect) can't bleed onto other layers.
                // An axis-aligned scissor cannot express a *rotated* box, so a
                // rotated draw is clipped in the fragment shader instead, in the
                // quad's own pre-rotation space. Both express the same region
                // when unrotated; the scissor is kept there so the existing
                // path is untouched.
                val clipW = effect.clipWidth
                val clipH = effect.clipHeight
                val hasClipBox = effect.clipX != null && effect.clipY != null &&
                    clipW != null && clipH != null && effect.renderHeight > 0
                val clipInShader = hasClipBox && effect.rotation != 0.0 &&
                    targetWidth > 0f && targetHeight > 0f
                // Must be set before bindAttributesAndUniforms(), which is what
                // actually uploads the recorded uniform values.
                glProgram.setFloatsUniform(
                    "uClipHalf",
                    if (clipInShader) {
                        floatArrayOf(
                            (clipW!! / targetWidth).toFloat().coerceAtMost(1f),
                            (clipH!! / targetHeight).toFloat().coerceAtMost(1f)
                        )
                    } else {
                        floatArrayOf(1f, 1f)
                    }
                )

                // Set attribute buffers with robust size detection
                val vertexData = GlUtil.getNormalizedCoordinateBounds()
                val vertexSize = if (vertexData.size == 8) 2 else 4
                glProgram.setBufferAttribute("aFramePosition", vertexData, vertexSize)

                val texData = GlUtil.getTextureCoordinateBounds()
                val texSize = if (texData.size == 8) 2 else 4
                glProgram.setBufferAttribute("aTexSamplingCoord", texData, texSize)

                glProgram.bindAttributesAndUniforms()

                val applyScissor = hasClipBox && effect.rotation == 0.0
                if (applyScissor) {
                    // Convert the clip box (canvas px, top-left origin) to GL
                    // scissor space (px, bottom-left origin).
                    val sx = effect.clipX!!.roundToInt()
                    val sw = clipW!!.roundToInt().coerceAtLeast(0)
                    val sh = clipH!!.roundToInt().coerceAtLeast(0)
                    val sy = (effect.renderHeight - (effect.clipY!! + clipH!!)).roundToInt()
                    GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
                    GLES20.glScissor(sx, sy, sw, sh)
                }

                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

                if (applyScissor) {
                    GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
                }
                GlUtil.checkGlError()
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e, presentationTimeUs)
            }
        }
    }
}
