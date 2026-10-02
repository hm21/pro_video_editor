package ch.waio.pro_video_editor.src.features.render.helpers

import android.opengl.GLES20
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.features.render.models.VideoEffectFrame
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * The glow step of the video effects on the GPU: the bright parts of the
 * picture the effect pass drew, blurred into a halo and screened over it, as
 * [VideoEffectMath] specifies.
 *
 * The effect pass draws into [beginPicture]'s intermediate instead of the
 * output. [finish] then runs four passes: a bright pass that averages blocks
 * of `scale` pixels into a small texture, a Gaussian over its rows and one
 * over its columns, and a screen pass that reads the halo back with bilinear
 * filtering and lays it over the picture into the output.
 *
 * Blurring at a lower resolution keeps the cost down. The scale leaves at
 * least four small pixels per standard deviation, which keeps the halo within
 * a step or two of [VideoEffectMath.gaussianBlur], the deviation the spec
 * allows for this step.
 */
@UnstableApi
internal class VideoEffectGlow {

    private val brightProgram = GlProgram(VERTEX_SHADER, BRIGHT_SHADER)
    private val blurProgram = GlProgram(VERTEX_SHADER, BLUR_SHADER)
    private val screenProgram = GlProgram(VERTEX_SHADER, SCREEN_SHADER)

    private var width = 0
    private var height = 0
    private var pictureTexture = NONE
    private var pictureFbo = NONE

    private var scale = 0
    private var smallWidth = 0
    private var smallHeight = 0
    private val smallTextures = intArrayOf(NONE, NONE)
    private val smallFbos = intArrayOf(NONE, NONE)

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
        ensureSmall(scaleFor(sigma))
        val threshold = frame.glowThreshold.coerceIn(0.0, 0.99).toFloat()

        GlUtil.focusFramebufferUsingCurrentContext(smallFbos[0], smallWidth, smallHeight)
        brightProgram.use()
        brightProgram.setSamplerTexIdUniform("uPicture", pictureTexture, 0)
        brightProgram.setFloatsUniform("uPictureSize", floatArrayOf(width.toFloat(), height.toFloat()))
        brightProgram.setFloatUniform("uScale", scale.toFloat())
        brightProgram.setFloatUniform("uGlow", frame.glow.toFloat())
        brightProgram.setFloatUniform("uThreshold", threshold)
        draw(brightProgram)

        if (sigma >= 0.5) {
            blur(from = 0, to = 1, direction = floatArrayOf(1f, 0f), sigma = sigma / scale)
            blur(from = 1, to = 0, direction = floatArrayOf(0f, 1f), sigma = sigma / scale)
        }

        GlUtil.focusFramebufferUsingCurrentContext(outputFbo, width, height)
        screenProgram.use()
        screenProgram.setSamplerTexIdUniform("uPicture", pictureTexture, 0)
        screenProgram.setSamplerTexIdUniform("uHalo", smallTextures[0], 1)
        screenProgram.setFloatsUniform("uPictureSize", floatArrayOf(width.toFloat(), height.toFloat()))
        screenProgram.setFloatsUniform(
            "uHaloSize", floatArrayOf(smallWidth.toFloat(), smallHeight.toFloat())
        )
        screenProgram.setFloatUniform("uScale", scale.toFloat())
        draw(screenProgram)
    }

    fun release() {
        deletePicture()
        deleteSmall()
        brightProgram.delete()
        blurProgram.delete()
        screenProgram.delete()
    }

    private fun blur(from: Int, to: Int, direction: FloatArray, sigma: Double) {
        GlUtil.focusFramebufferUsingCurrentContext(smallFbos[to], smallWidth, smallHeight)
        blurProgram.use()
        blurProgram.setSamplerTexIdUniform("uSource", smallTextures[from], 0)
        blurProgram.setFloatsUniform("uSize", floatArrayOf(smallWidth.toFloat(), smallHeight.toFloat()))
        blurProgram.setFloatsUniform("uDirection", direction)
        blurProgram.setFloatUniform("uSigma", sigma.toFloat())
        draw(blurProgram)
    }

    private fun draw(program: GlProgram) {
        val vertices = GlUtil.getNormalizedCoordinateBounds()
        program.setBufferAttribute("aFramePosition", vertices, if (vertices.size == 8) 2 else 4)
        program.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GlUtil.checkGlError()
    }

    private fun ensureSmall(scale: Int) {
        val w = (width + scale - 1) / scale
        val h = (height + scale - 1) / scale
        if (scale == this.scale && w == smallWidth && h == smallHeight && smallTextures[0] != NONE) return
        deleteSmall()
        for (i in 0..1) {
            smallTextures[i] = GlUtil.createTexture(w, h, /* useHighPrecisionColorComponents= */ false)
            smallFbos[i] = GlUtil.createFboForTexture(smallTextures[i])
        }
        this.scale = scale
        smallWidth = w
        smallHeight = h
    }

    private fun deletePicture() {
        if (pictureFbo != NONE) GlUtil.deleteFbo(pictureFbo)
        if (pictureTexture != NONE) GlUtil.deleteTexture(pictureTexture)
        pictureFbo = NONE
        pictureTexture = NONE
    }

    private fun deleteSmall() {
        for (i in 0..1) {
            if (smallFbos[i] != NONE) GlUtil.deleteFbo(smallFbos[i])
            if (smallTextures[i] != NONE) GlUtil.deleteTexture(smallTextures[i])
            smallFbos[i] = NONE
            smallTextures[i] = NONE
        }
    }

    companion object {
        private const val NONE = -1

        /** The largest block the bright pass averages; its loops stop here. */
        private const val MAX_SCALE = 32

        /**
         * The downscale for a blur of [sigma] pixels: at least four small
         * pixels per standard deviation, at most [MAX_SCALE].
         */
        fun scaleFor(sigma: Double): Int = min(MAX_SCALE, max(1, floor(sigma / 4).toInt()))

        /** The framebuffer the caller drew into last, so the glow can return to it. */
        fun currentFramebuffer(): Int {
            val binding = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, binding, 0)
            return binding[0]
        }

        private const val VERTEX_SHADER =
            "attribute vec4 aFramePosition;\n" +
            "void main() {\n" +
            "  gl_Position = aFramePosition;\n" +
            "}"

        private const val PRECISION =
            "#ifdef GL_FRAGMENT_PRECISION_HIGH\n" +
            "precision highp float;\n" +
            "#else\n" +
            "precision mediump float;\n" +
            "#endif\n"

        // Averages a block of uScale by uScale picture pixels of
        // min(1, glow * k * c), with k how far the pixel's brightness is past
        // the threshold. Blocks at the right and top edges average only the
        // pixels the picture has.
        private const val BRIGHT_SHADER = PRECISION +
            "uniform sampler2D uPicture;\n" +
            "uniform vec2 uPictureSize;\n" +
            "uniform float uScale;\n" +
            "uniform float uGlow;\n" +
            "uniform float uThreshold;\n" +
            "void main() {\n" +
            "  vec2 block = floor(gl_FragCoord.xy) * uScale;\n" +
            "  vec3 sum = vec3(0.0);\n" +
            "  float count = 0.0;\n" +
            "  for (int j = 0; j < 32; j++) {\n" +
            "    if (float(j) >= uScale) break;\n" +
            "    for (int i = 0; i < 32; i++) {\n" +
            "      if (float(i) >= uScale) break;\n" +
            "      vec2 texel = block + vec2(float(i), float(j));\n" +
            "      if (texel.x < uPictureSize.x && texel.y < uPictureSize.y) {\n" +
            "        vec3 c = texture2D(uPicture, (texel + 0.5) / uPictureSize).rgb;\n" +
            "        float l = dot(c, vec3(0.2126, 0.7152, 0.0722));\n" +
            "        float k = clamp((l - uThreshold) / (1.0 - uThreshold), 0.0, 1.0);\n" +
            "        sum += min(vec3(1.0), uGlow * k * c);\n" +
            "        count += 1.0;\n" +
            "      }\n" +
            "    }\n" +
            "  }\n" +
            "  gl_FragColor = vec4(sum / max(count, 1.0), 1.0);\n" +
            "}"

        // One direction of the Gaussian, reaching ceil(3 sigma) pixels to each
        // side, with the edge pixels repeated.
        private const val BLUR_SHADER = PRECISION +
            "uniform sampler2D uSource;\n" +
            "uniform vec2 uSize;\n" +
            "uniform vec2 uDirection;\n" +
            "uniform float uSigma;\n" +
            "void main() {\n" +
            "  vec2 p = floor(gl_FragCoord.xy);\n" +
            "  float reach = ceil(3.0 * uSigma);\n" +
            "  vec3 sum = vec3(0.0);\n" +
            "  float total = 0.0;\n" +
            "  for (int k = -64; k <= 64; k++) {\n" +
            "    float offset = float(k);\n" +
            "    if (abs(offset) > reach) continue;\n" +
            "    float weight = exp(-offset * offset / (2.0 * uSigma * uSigma));\n" +
            "    vec2 texel = clamp(p + uDirection * offset, vec2(0.0), uSize - 1.0);\n" +
            "    sum += weight * texture2D(uSource, (texel + 0.5) / uSize).rgb;\n" +
            "    total += weight;\n" +
            "  }\n" +
            "  gl_FragColor = vec4(sum / total, 1.0);\n" +
            "}"

        // The halo, read with bilinear filtering where the full-size pixel's
        // center falls in the small texture, screened over the picture.
        private const val SCREEN_SHADER = PRECISION +
            "uniform sampler2D uPicture;\n" +
            "uniform sampler2D uHalo;\n" +
            "uniform vec2 uPictureSize;\n" +
            "uniform vec2 uHaloSize;\n" +
            "uniform float uScale;\n" +
            "void main() {\n" +
            "  vec2 p = floor(gl_FragCoord.xy) + 0.5;\n" +
            "  vec4 c = texture2D(uPicture, p / uPictureSize);\n" +
            "  vec3 halo = texture2D(uHalo, p / uScale / uHaloSize).rgb;\n" +
            "  gl_FragColor = vec4(clamp(1.0 - (1.0 - c.rgb) * (1.0 - halo), 0.0, 1.0), c.a);\n" +
            "}"
    }
}
