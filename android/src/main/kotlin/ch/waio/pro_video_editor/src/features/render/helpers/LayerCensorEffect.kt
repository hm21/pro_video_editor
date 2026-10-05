package ch.waio.pro_video_editor.src.features.render.helpers

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.OverlaySettings
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import ch.waio.pro_video_editor.src.features.render.models.LayerCensorConfig
import kotlin.math.roundToInt

/**
 * An image layer that hides the picture beneath it instead of drawing its
 * image: the frame composed so far — the video and every image layer before
 * this one — is blurred or pixelated wherever the layer's image is opaque.
 *
 * [mask] is the overlay the layer would otherwise be drawn as, so the area
 * lands exactly where that overlay would: its position, its size, its rotation
 * (baked into the bitmap by `prepareOverlay`) and its animations. Its alpha,
 * times the overlay's alpha scale, is how much of the hidden picture replaces
 * the original one. See [CensorMaskPlacement] for the mapping.
 *
 * The blur reuses the glow's downscaled Gaussian ([VideoEffectGlow]): blocks
 * of `scale` pixels are averaged into a small texture with a margin that
 * repeats the edge pixels, blurred over its rows and its columns, and read
 * back with bilinear filtering. Pixelate needs no extra pass: every pixel of a
 * block copies the pixel at the block's start + `block / 2`, with the blocks
 * counted from the top-left corner of the mask's quad, so the area starts on
 * whole blocks, as the Apple renderer does.
 */
@UnstableApi
internal class LayerCensorEffect(
    private val mask: BitmapOverlay,
    private val censor: LayerCensorConfig,
) : GlEffect {

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
        if (useHdr) {
            // An ES 2.0 SDR program, like the chroma key and the video effects.
            // RenderVideo pre-transcodes HDR sources whenever there are image
            // layers, so this guards that gate rather than an expected path.
            throw VideoFrameProcessingException("A censor layer does not support HDR input")
        }
        return CensorShaderProgram(mask, censor)
    }

    @UnstableApi
    private class CensorShaderProgram(
        private val mask: BitmapOverlay,
        private val censor: LayerCensorConfig,
    ) : BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ false, /* texturePoolCapacity= */ 1) {

        private val isBlur = censor.type == LayerCensorConfig.Type.BLUR

        private val combineProgram = GlProgram(
            VideoEffectGlow.VERTEX_SHADER,
            if (isBlur) BLUR_COMBINE_SHADER else PIXELATE_SHADER,
        )
        private val downsampleProgram =
            if (isBlur) GlProgram(VideoEffectGlow.VERTEX_SHADER, DOWNSAMPLE_SHADER) else null
        private val blurProgram =
            if (isBlur) GlProgram(VideoEffectGlow.VERTEX_SHADER, VideoEffectGlow.BLUR_SHADER) else null

        private var width = 0
        private var height = 0

        private var scale = 0
        private var margin = 0
        private var smallWidth = 0
        private var smallHeight = 0
        private val smallTextures = intArrayOf(NONE, NONE)
        private val smallFbos = intArrayOf(NONE, NONE)

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            width = inputWidth
            height = inputHeight
            mask.configure(Size(inputWidth, inputHeight))
            return Size(inputWidth, inputHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            try {
                val outputFbo = VideoEffectGlow.currentFramebuffer()
                val settings = mask.getOverlaySettings(presentationTimeUs)
                val maskTexId = mask.getTextureId(presentationTimeUs)
                val maskSize = mask.getTextureSize(presentationTimeUs)
                val placement = CensorMaskPlacement.of(
                    settings.backgroundAnchor(),
                    settings.overlayAnchor(),
                    settings.scaleXY(),
                    maskWidth = maskSize.width,
                    maskHeight = maskSize.height,
                    frameWidth = width,
                    frameHeight = height,
                )
                val alpha = settings.alphaScale
                val sigma = censor.strength

                if (isBlur && alpha > 0f) blurIntoSmall(inputTexId, sigma)

                GlUtil.focusFramebufferUsingCurrentContext(outputFbo, width, height)
                val program = combineProgram
                program.use()
                program.setSamplerTexIdUniform("uPicture", inputTexId, 0)
                program.setSamplerTexIdUniform("uMask", maskTexId, 1)
                program.setFloatsUniform("uPictureSize", floatArrayOf(width.toFloat(), height.toFloat()))
                program.setFloatsUniform("uMaskOrigin", placement.origin)
                program.setFloatsUniform("uMaskExtent", placement.extent)
                program.setFloatUniform("uAlpha", alpha)
                if (isBlur) {
                    // Without a blur pass (alpha 0) the small texture may not
                    // exist yet; the shader never reads it then, but every
                    // sampler has to be bound, so it gets the picture instead.
                    val hidden = if (alpha > 0f) smallTextures[0] else inputTexId
                    program.setSamplerTexIdUniform("uHidden", hidden, 2)
                    program.setFloatsUniform(
                        "uHiddenSize", floatArrayOf(smallWidth.toFloat(), smallHeight.toFloat())
                    )
                    program.setFloatUniform("uScale", scale.toFloat())
                    program.setFloatUniform("uMargin", margin.toFloat())
                } else {
                    program.setFloatUniform("uBlock", censor.blockSize.toFloat())
                    program.setFloatsUniform("uAnchor", placement.topLeftPixel(width, height))
                }
                draw(program)
                // The mask and the blur were bound on later units; hand the
                // first back active.
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e, presentationTimeUs)
            }
        }

        /** Averages the picture into the small texture and blurs it there. */
        private fun blurIntoSmall(inputTexId: Int, sigma: Double) {
            ensureSmall(sigma)
            val downsample = downsampleProgram!!
            GlUtil.focusFramebufferUsingCurrentContext(smallFbos[0], smallWidth, smallHeight)
            downsample.use()
            downsample.setSamplerTexIdUniform("uPicture", inputTexId, 0)
            downsample.setFloatsUniform("uPictureSize", floatArrayOf(width.toFloat(), height.toFloat()))
            downsample.setFloatUniform("uScale", scale.toFloat())
            downsample.setFloatUniform("uMargin", margin.toFloat())
            draw(downsample)

            if (sigma >= 0.5) {
                blur(from = 0, to = 1, direction = floatArrayOf(1f, 0f), sigma = sigma / scale)
                blur(from = 1, to = 0, direction = floatArrayOf(0f, 1f), sigma = sigma / scale)
            }
        }

        private fun blur(from: Int, to: Int, direction: FloatArray, sigma: Double) {
            val program = blurProgram!!
            GlUtil.focusFramebufferUsingCurrentContext(smallFbos[to], smallWidth, smallHeight)
            program.use()
            program.setSamplerTexIdUniform("uSource", smallTextures[from], 0)
            program.setFloatsUniform("uSize", floatArrayOf(smallWidth.toFloat(), smallHeight.toFloat()))
            program.setFloatsUniform("uDirection", direction)
            program.setFloatUniform("uSigma", sigma.toFloat())
            draw(program)
        }

        private fun draw(program: GlProgram) {
            val vertices = GlUtil.getNormalizedCoordinateBounds()
            program.setBufferAttribute("aFramePosition", vertices, if (vertices.size == 8) 2 else 4)
            program.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GlUtil.checkGlError()
        }

        /** Sizes the small textures for a blur of [sigma] pixels. */
        private fun ensureSmall(sigma: Double) {
            val scale = VideoEffectGlow.scaleFor(sigma)
            val margin = VideoEffectGlow.marginFor(sigma, scale)
            val w = (width + scale - 1) / scale + 2 * margin
            val h = (height + scale - 1) / scale + 2 * margin
            this.margin = margin
            if (scale == this.scale && w == smallWidth && h == smallHeight && smallTextures[0] != NONE) {
                return
            }
            deleteSmall()
            for (i in 0..1) {
                smallTextures[i] = GlUtil.createTexture(w, h, /* useHighPrecisionColorComponents= */ false)
                smallFbos[i] = GlUtil.createFboForTexture(smallTextures[i])
            }
            this.scale = scale
            smallWidth = w
            smallHeight = h
        }

        private fun deleteSmall() {
            for (i in 0..1) {
                if (smallFbos[i] != NONE) GlUtil.deleteFbo(smallFbos[i])
                if (smallTextures[i] != NONE) GlUtil.deleteTexture(smallTextures[i])
                smallFbos[i] = NONE
                smallTextures[i] = NONE
            }
        }

        override fun release() {
            super.release()
            try {
                deleteSmall()
                // The overlay owns the mask texture, as it would inside an
                // OverlayEffect, whose program releases it the same way.
                mask.release()
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e)
            } finally {
                try {
                    combineProgram.delete()
                    downsampleProgram?.delete()
                    blurProgram?.delete()
                } catch (e: Exception) {
                    throw VideoFrameProcessingException(e)
                }
            }
        }
    }

    private companion object {
        private const val NONE = -1

        private fun OverlaySettings.backgroundAnchor(): FloatArray =
            floatArrayOf(backgroundFrameAnchor.first, backgroundFrameAnchor.second)

        private fun OverlaySettings.overlayAnchor(): FloatArray =
            floatArrayOf(overlayFrameAnchor.first, overlayFrameAnchor.second)

        private fun OverlaySettings.scaleXY(): FloatArray = floatArrayOf(scale.first, scale.second)

        // The mask's alpha at a pixel center, in GL's bottom-up pixel space.
        // [CensorMaskPlacement] maps the frame onto the overlay quad's [-1, 1]
        // coordinates: v = (P - origin) / extent, with P the pixel center in
        // normalized device coordinates. A bitmap's row 0 is uploaded at t = 0,
        // so t runs downwards. Outside the quad the layer is not there at all.
        private const val MASK_FUNCTION =
            "uniform sampler2D uMask;\n" +
            "uniform vec2 uMaskOrigin;\n" +
            "uniform vec2 uMaskExtent;\n" +
            "uniform float uAlpha;\n" +
            "float maskAt(vec2 p, vec2 size) {\n" +
            "  vec2 v = (2.0 * p / size - 1.0 - uMaskOrigin) / uMaskExtent;\n" +
            "  vec2 st = vec2(0.5 * v.x + 0.5, 0.5 - 0.5 * v.y);\n" +
            "  if (st.x < 0.0 || st.x > 1.0 || st.y < 0.0 || st.y > 1.0) return 0.0;\n" +
            "  return texture2D(uMask, st).a * uAlpha;\n" +
            "}\n"

        // Averages a block of uScale by uScale picture pixels into one small
        // pixel. The small texture starts uMargin blocks before the picture,
        // and blocks past its edges average the repeated edge pixels.
        private const val DOWNSAMPLE_SHADER = VideoEffectGlow.PRECISION +
            "uniform sampler2D uPicture;\n" +
            "uniform vec2 uPictureSize;\n" +
            "uniform float uScale;\n" +
            "uniform float uMargin;\n" +
            "void main() {\n" +
            "  vec2 block = (floor(gl_FragCoord.xy) - uMargin) * uScale;\n" +
            "  vec3 sum = vec3(0.0);\n" +
            "  for (int j = 0; j < 32; j++) {\n" +
            "    if (float(j) >= uScale) break;\n" +
            "    for (int i = 0; i < 32; i++) {\n" +
            "      if (float(i) >= uScale) break;\n" +
            "      vec2 texel = clamp(block + vec2(float(i), float(j)), vec2(0.0), uPictureSize - 1.0);\n" +
            "      sum += texture2D(uPicture, (texel + 0.5) / uPictureSize).rgb;\n" +
            "    }\n" +
            "  }\n" +
            "  gl_FragColor = vec4(sum / (uScale * uScale), 1.0);\n" +
            "}"

        // The blurred picture, read with bilinear filtering where the pixel's
        // center falls in the small texture, mixed in by the mask.
        private const val BLUR_COMBINE_SHADER = VideoEffectGlow.PRECISION +
            MASK_FUNCTION +
            "uniform sampler2D uPicture;\n" +
            "uniform sampler2D uHidden;\n" +
            "uniform vec2 uPictureSize;\n" +
            "uniform vec2 uHiddenSize;\n" +
            "uniform float uScale;\n" +
            "uniform float uMargin;\n" +
            "void main() {\n" +
            "  vec2 p = floor(gl_FragCoord.xy) + 0.5;\n" +
            "  vec4 c = texture2D(uPicture, p / uPictureSize);\n" +
            "  float m = maskAt(p, uPictureSize);\n" +
            "  if (m <= 0.0) {\n" +
            "    gl_FragColor = c;\n" +
            "    return;\n" +
            "  }\n" +
            "  vec3 hidden = texture2D(uHidden, (p / uScale + uMargin) / uHiddenSize).rgb;\n" +
            "  gl_FragColor = vec4(mix(c.rgb, hidden, m), c.a);\n" +
            "}"

        // Every pixel of a block copies the pixel at the block's start plus
        // floor(block / 2), the blocks counted from uAnchor, the mask's
        // top-left pixel (top-origin); a block cut off by the frame edge reads
        // its last pixel instead. (a + 0.5) / b keeps the division of whole
        // numbers clear of rounding at mediump.
        private const val PIXELATE_SHADER = VideoEffectGlow.PRECISION +
            MASK_FUNCTION +
            "uniform sampler2D uPicture;\n" +
            "uniform vec2 uPictureSize;\n" +
            "uniform float uBlock;\n" +
            "uniform vec2 uAnchor;\n" +
            "void main() {\n" +
            "  vec2 fc = floor(gl_FragCoord.xy);\n" +
            "  vec4 c = texture2D(uPicture, (fc + 0.5) / uPictureSize);\n" +
            "  float m = maskAt(fc + 0.5, uPictureSize);\n" +
            "  if (m <= 0.0) {\n" +
            "    gl_FragColor = c;\n" +
            "    return;\n" +
            "  }\n" +
            "  vec2 top = vec2(fc.x, uPictureSize.y - 1.0 - fc.y);\n" +
            "  vec2 start = floor((top - uAnchor + 0.5) / uBlock) * uBlock + uAnchor;\n" +
            "  vec2 source = clamp(start + floor(uBlock / 2.0), vec2(0.0), uPictureSize - 1.0);\n" +
            "  vec2 st = vec2((source.x + 0.5) / uPictureSize.x, 1.0 - (source.y + 0.5) / uPictureSize.y);\n" +
            "  vec3 hidden = texture2D(uPicture, st).rgb;\n" +
            "  gl_FragColor = vec4(mix(c.rgb, hidden, m), c.a);\n" +
            "}"
    }
}

/**
 * Where a censor layer's mask lies in the frame, as Media3's overlay shader
 * places the same overlay.
 *
 * Media3 maps a point `v` of the overlay quad (`[-1, 1]` on both axes) to the
 * frame's normalized device coordinates as
 * `P = backgroundAnchor + (mask / frame) * scale * (v - overlayAnchor)`,
 * per axis. Inverted, `v = (P - origin) / extent` with
 * `origin = backgroundAnchor - extent * overlayAnchor` and
 * `extent = (mask / frame) * scale`. The censor shader evaluates that at every
 * pixel center and samples the mask where `v` falls inside the quad.
 *
 * The overlay's rotation is not part of it: `prepareOverlay` turns the bitmap
 * itself and never sets a rotation on the settings.
 */
internal data class CensorMaskPlacement(val origin: FloatArray, val extent: FloatArray) {

    /**
     * The quad coordinates of the frame point [ndcX], [ndcY] (normalized
     * device coordinates, y up), the same arithmetic as the shader's.
     */
    fun quadCoordinateOf(ndcX: Float, ndcY: Float): Pair<Float, Float> =
        (ndcX - origin[0]) / extent[0] to (ndcY - origin[1]) / extent[1]

    /**
     * The quad's top-left corner in whole pixels of a [frameWidth] by
     * [frameHeight] frame, counted from its top-left corner: where a censor
     * layer's pixelate blocks start.
     */
    fun topLeftPixel(frameWidth: Int, frameHeight: Int): FloatArray {
        // The corner v = (-1, 1) of the quad, P = origin + extent * v.
        val ndcX = origin[0] - extent[0]
        val ndcY = origin[1] + extent[1]
        return floatArrayOf(
            ((ndcX + 1f) / 2f * frameWidth).roundToInt().toFloat(),
            ((1f - ndcY) / 2f * frameHeight).roundToInt().toFloat(),
        )
    }

    override fun equals(other: Any?): Boolean =
        other is CensorMaskPlacement &&
            origin.contentEquals(other.origin) &&
            extent.contentEquals(other.extent)

    override fun hashCode(): Int = 31 * origin.contentHashCode() + extent.contentHashCode()

    companion object {
        fun of(
            backgroundAnchor: FloatArray,
            overlayAnchor: FloatArray,
            scale: FloatArray,
            maskWidth: Int,
            maskHeight: Int,
            frameWidth: Int,
            frameHeight: Int,
        ): CensorMaskPlacement {
            val extent = floatArrayOf(
                maskWidth.toFloat() / frameWidth * scale[0],
                maskHeight.toFloat() / frameHeight * scale[1],
            )
            val origin = floatArrayOf(
                backgroundAnchor[0] - extent[0] * overlayAnchor[0],
                backgroundAnchor[1] - extent[1] * overlayAnchor[1],
            )
            return CensorMaskPlacement(origin, extent)
        }
    }
}
