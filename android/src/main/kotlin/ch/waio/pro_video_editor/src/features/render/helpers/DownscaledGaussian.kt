package ch.waio.pro_video_editor.src.features.render.helpers

import android.opengl.GLES20
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.UnstableApi
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * A Gaussian blur of a picture at a lower resolution, shared by the glow
 * ([VideoEffectGlow]) and the blur of a censor layer ([LayerCensorEffect]).
 *
 * The caller's downsample pass, drawn after [beginDownsample], averages blocks
 * of [scale] by [scale] picture pixels into the small texture, which starts
 * [margin] blocks before the picture. [blur] then runs the Gaussian over its
 * rows and over its columns, and the caller reads [texture] back with bilinear
 * filtering where a picture pixel's center `p` falls in it:
 * `(p / scale + margin) / size`.
 *
 * Blurring at a lower resolution keeps the cost down. The scale leaves at
 * least four small pixels per standard deviation, which keeps the result
 * within a step or two of a full-resolution Gaussian.
 *
 * The margin is as wide as the blur reaches, and its blocks average the
 * picture's repeated edge pixels. Repeating the small texture's edge instead
 * would first spread a thin line at the picture's edge over a whole block.
 */
@UnstableApi
internal class DownscaledGaussian {

    private val blurProgram = GlProgram(VideoEffectGlow.VERTEX_SHADER, BLUR_SHADER)

    /** Picture pixels per small pixel, on each axis. */
    var scale = 0
        private set

    /** Small pixels the small texture adds around the picture on each side. */
    var margin = 0
        private set

    /** Width of the small texture, margin included. */
    var width = 0
        private set

    /** Height of the small texture, margin included. */
    var height = 0
        private set

    private val textures = intArrayOf(NONE, NONE)
    private val fbos = intArrayOf(NONE, NONE)

    /** The small texture: the downsampled picture, blurred once [blur] ran. */
    val texture: Int get() = textures[0]

    /**
     * Sizes the small texture for a [pictureWidth] x [pictureHeight] picture
     * and a blur of [sigma] pixels, and focuses it for the caller's downsample
     * pass, which reads [scale] and [margin].
     */
    fun beginDownsample(pictureWidth: Int, pictureHeight: Int, sigma: Double) {
        ensure(pictureWidth, pictureHeight, sigma)
        GlUtil.focusFramebufferUsingCurrentContext(fbos[0], width, height)
    }

    /**
     * Blurs the downsampled picture by [sigma] picture pixels, over its rows
     * and then its columns. The result is back in [texture].
     */
    fun blur(sigma: Double) {
        if (sigma < 0.5) return
        pass(from = 0, to = 1, direction = floatArrayOf(1f, 0f), sigma = sigma / scale)
        pass(from = 1, to = 0, direction = floatArrayOf(0f, 1f), sigma = sigma / scale)
    }

    fun release() {
        delete()
        blurProgram.delete()
    }

    private fun pass(from: Int, to: Int, direction: FloatArray, sigma: Double) {
        GlUtil.focusFramebufferUsingCurrentContext(fbos[to], width, height)
        blurProgram.use()
        blurProgram.setSamplerTexIdUniform("uSource", textures[from], 0)
        blurProgram.setFloatsUniform("uSize", floatArrayOf(width.toFloat(), height.toFloat()))
        blurProgram.setFloatsUniform("uDirection", direction)
        blurProgram.setFloatUniform("uSigma", sigma.toFloat())
        draw(blurProgram)
    }

    private fun ensure(pictureWidth: Int, pictureHeight: Int, sigma: Double) {
        val scale = scaleFor(sigma)
        val margin = marginFor(sigma, scale)
        val w = (pictureWidth + scale - 1) / scale + 2 * margin
        val h = (pictureHeight + scale - 1) / scale + 2 * margin
        this.margin = margin
        if (scale == this.scale && w == width && h == height && textures[0] != NONE) return
        delete()
        for (i in 0..1) {
            textures[i] = GlUtil.createTexture(w, h, /* useHighPrecisionColorComponents= */ false)
            fbos[i] = GlUtil.createFboForTexture(textures[i])
        }
        this.scale = scale
        width = w
        height = h
    }

    private fun delete() {
        for (i in 0..1) {
            if (fbos[i] != NONE) GlUtil.deleteFbo(fbos[i])
            if (textures[i] != NONE) GlUtil.deleteTexture(textures[i])
            fbos[i] = NONE
            textures[i] = NONE
        }
    }

    companion object {
        private const val NONE = -1

        /**
         * The largest block a downsample pass averages; the downsample
         * shaders' loops stop at 32.
         */
        private const val MAX_SCALE = 32

        /** The farthest the blur reaches, in small pixels; its loop stops here. */
        private const val MAX_REACH = 64

        /**
         * The downscale for a blur of [sigma] pixels: at least four small
         * pixels per standard deviation, at most [MAX_SCALE].
         */
        fun scaleFor(sigma: Double): Int = min(MAX_SCALE, max(1, floor(sigma / 4).toInt()))

        /**
         * The small pixels the blur of [sigma] pixels reaches at [scale], which
         * the small texture adds around the picture; none without a blur.
         */
        fun marginFor(sigma: Double, scale: Int): Int =
            if (sigma < 0.5) 0 else min(MAX_REACH, ceil(3 * sigma / scale).toInt())

        /** Draws [program] over the whole focused framebuffer. */
        fun draw(program: GlProgram) {
            val vertices = GlUtil.getNormalizedCoordinateBounds()
            program.setBufferAttribute("aFramePosition", vertices, if (vertices.size == 8) 2 else 4)
            program.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GlUtil.checkGlError()
        }

        // One direction of the Gaussian, reaching ceil(3 sigma) pixels to each
        // side, at most MAX_REACH. The margin keeps it inside the texture; the
        // clamp only guards the reads.
        private const val BLUR_SHADER = VideoEffectGlow.PRECISION +
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
    }
}
