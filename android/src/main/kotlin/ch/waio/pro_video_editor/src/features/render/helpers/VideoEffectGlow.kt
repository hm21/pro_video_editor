package ch.waio.pro_video_editor.src.features.render.helpers

import android.opengl.GLES20
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.features.render.models.VideoEffectFrame

/**
 * The glow step of the video effects on the GPU: the bright parts of the
 * picture the effect pass drew, blurred into a halo and screened over it, as
 * [VideoEffectMath] specifies.
 *
 * The effect pass draws into [beginPicture]'s intermediate instead of the
 * output. [finish] then runs four passes: a bright pass that averages blocks
 * of `scale` pixels into a small texture, a Gaussian over its rows and one
 * over its columns ([DownscaledGaussian]), and a screen pass that reads the
 * halo back with bilinear filtering and lays it over the picture into the
 * output.
 *
 * The downscaled Gaussian stays within a step or two of
 * [VideoEffectMath.gaussianBlur], the deviation the spec allows for this step.
 * The spec repeats the edge pixels beyond the frame, so a thin bright line
 * right at the edge glows as strongly as a wide bright area there, which the
 * small texture's margin of repeated edge pixels keeps.
 */
@UnstableApi
internal class VideoEffectGlow {

    private val brightProgram = GlProgram(VERTEX_SHADER, BRIGHT_SHADER)
    private val screenProgram = GlProgram(VERTEX_SHADER, SCREEN_SHADER)
    private val halo = DownscaledGaussian()

    private var width = 0
    private var height = 0
    private var pictureTexture = NONE
    private var pictureFbo = NONE

    /** Points the next draw at the full-size intermediate the glow reads. */
    fun beginPicture(width: Int, height: Int) {
        if (width != this.width || height != this.height || pictureTexture == NONE) {
            deletePicture()
            pictureTexture = GlUtil.createTexture(width, height, /* useHighPrecisionColorComponents= */ false)
            pictureFbo = GlUtil.createFboForTexture(pictureTexture)
            this.width = width
            this.height = height
        }
        GlUtil.focusFramebufferUsingCurrentContext(pictureFbo, width, height)
        GlUtil.clearFocusedBuffers()
    }

    /**
     * Screens the glow of [frame] over the picture drawn since [beginPicture]
     * and writes the result to the framebuffer [outputFbo].
     */
    fun finish(frame: VideoEffectFrame, outputFbo: Int) {
        val sigma = frame.glowRadius * height
        val threshold = frame.glowThreshold.coerceIn(0.0, 0.99).toFloat()

        halo.beginDownsample(width, height, sigma)
        brightProgram.use()
        brightProgram.setSamplerTexIdUniform("uPicture", pictureTexture, 0)
        brightProgram.setFloatsUniform("uPictureSize", floatArrayOf(width.toFloat(), height.toFloat()))
        brightProgram.setFloatUniform("uScale", halo.scale.toFloat())
        brightProgram.setFloatUniform("uMargin", halo.margin.toFloat())
        brightProgram.setFloatUniform("uGlow", frame.glow.toFloat())
        brightProgram.setFloatUniform("uThreshold", threshold)
        DownscaledGaussian.draw(brightProgram)

        halo.blur(sigma)

        GlUtil.focusFramebufferUsingCurrentContext(outputFbo, width, height)
        screenProgram.use()
        screenProgram.setSamplerTexIdUniform("uPicture", pictureTexture, 0)
        screenProgram.setSamplerTexIdUniform("uHalo", halo.texture, 1)
        screenProgram.setFloatsUniform("uPictureSize", floatArrayOf(width.toFloat(), height.toFloat()))
        screenProgram.setFloatsUniform(
            "uHaloSize", floatArrayOf(halo.width.toFloat(), halo.height.toFloat())
        )
        screenProgram.setFloatUniform("uScale", halo.scale.toFloat())
        screenProgram.setFloatUniform("uMargin", halo.margin.toFloat())
        DownscaledGaussian.draw(screenProgram)
        // The halo was bound on the second unit; hand the first back active.
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    }

    fun release() {
        deletePicture()
        halo.release()
        brightProgram.delete()
        screenProgram.delete()
    }

    private fun deletePicture() {
        if (pictureFbo != NONE) GlUtil.deleteFbo(pictureFbo)
        if (pictureTexture != NONE) GlUtil.deleteTexture(pictureTexture)
        pictureFbo = NONE
        pictureTexture = NONE
    }

    companion object {
        private const val NONE = -1

        /** The framebuffer the caller drew into last, so the glow can return to it. */
        fun currentFramebuffer(): Int {
            val binding = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, binding, 0)
            return binding[0]
        }

        internal const val VERTEX_SHADER =
            "attribute vec4 aFramePosition;\n" +
            "void main() {\n" +
            "  gl_Position = aFramePosition;\n" +
            "}"

        internal const val PRECISION =
            "#ifdef GL_FRAGMENT_PRECISION_HIGH\n" +
            "precision highp float;\n" +
            "#else\n" +
            "precision mediump float;\n" +
            "#endif\n"

        // Averages a block of uScale by uScale picture pixels of
        // min(1, glow * k * c), with k how far the pixel's brightness is past
        // the threshold. The small texture starts uMargin blocks before the
        // picture, and blocks past its edges average the repeated edge pixels.
        private const val BRIGHT_SHADER = PRECISION +
            "uniform sampler2D uPicture;\n" +
            "uniform vec2 uPictureSize;\n" +
            "uniform float uScale;\n" +
            "uniform float uMargin;\n" +
            "uniform float uGlow;\n" +
            "uniform float uThreshold;\n" +
            "void main() {\n" +
            "  vec2 block = (floor(gl_FragCoord.xy) - uMargin) * uScale;\n" +
            "  vec3 sum = vec3(0.0);\n" +
            "  for (int j = 0; j < 32; j++) {\n" +
            "    if (float(j) >= uScale) break;\n" +
            "    for (int i = 0; i < 32; i++) {\n" +
            "      if (float(i) >= uScale) break;\n" +
            "      vec2 texel = clamp(block + vec2(float(i), float(j)), vec2(0.0), uPictureSize - 1.0);\n" +
            "      vec3 c = texture2D(uPicture, (texel + 0.5) / uPictureSize).rgb;\n" +
            "      float l = dot(c, vec3(0.2126, 0.7152, 0.0722));\n" +
            "      float k = clamp((l - uThreshold) / (1.0 - uThreshold), 0.0, 1.0);\n" +
            "      sum += min(vec3(1.0), uGlow * k * c);\n" +
            "    }\n" +
            "  }\n" +
            "  gl_FragColor = vec4(sum / (uScale * uScale), 1.0);\n" +
            "}"

        // The halo, read with bilinear filtering where the full-size pixel's
        // center falls in the small texture, screened over the picture.
        private const val SCREEN_SHADER = PRECISION +
            "uniform sampler2D uPicture;\n" +
            "uniform sampler2D uHalo;\n" +
            "uniform vec2 uPictureSize;\n" +
            "uniform vec2 uHaloSize;\n" +
            "uniform float uScale;\n" +
            "uniform float uMargin;\n" +
            "void main() {\n" +
            "  vec2 p = floor(gl_FragCoord.xy) + 0.5;\n" +
            "  vec4 c = texture2D(uPicture, p / uPictureSize);\n" +
            "  vec3 halo = texture2D(uHalo, (p / uScale + uMargin) / uHaloSize).rgb;\n" +
            "  gl_FragColor = vec4(clamp(1.0 - (1.0 - c.rgb) * (1.0 - halo), 0.0, 1.0), c.a);\n" +
            "}"
    }
}
