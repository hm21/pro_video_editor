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
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * An image layer that hides the picture beneath it instead of drawing its
 * image: the frame composed so far — the video and every image layer before
 * this one — is blurred or pixelated wherever the layer's image is opaque.
 *
 * [mask] is the overlay the layer would otherwise be drawn as, so the area
 * lands exactly where that overlay would: its position, its size, its rotation
 * (baked into the bitmap by `prepareOverlay`) and its animations, including
 * the tilt of a wiggle. Its alpha,
 * times the overlay's alpha scale, is how much of the hidden picture replaces
 * the original one. See [CensorMaskPlacement] for the mapping.
 *
 * The blur is the glow's downscaled Gaussian ([DownscaledGaussian]): blocks
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
        private val hidden = if (isBlur) DownscaledGaussian() else null

        private var width = 0
        private var height = 0

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
                    rotationDegrees = settings.rotationDegrees,
                )
                // Nothing is hidden while the layer is faded out, scaled down
                // to nothing (a scale animation from 0) or wholly off the
                // frame (a slide from an edge). The shader then copies the
                // picture without dividing by the zero extent, and the blur
                // is skipped.
                val alpha = if (placement.coversFrame()) settings.alphaScale else 0f

                if (hidden != null && alpha > 0f) blurIntoSmall(hidden, inputTexId)

                GlUtil.focusFramebufferUsingCurrentContext(outputFbo, width, height)
                val program = combineProgram
                program.use()
                program.setSamplerTexIdUniform("uPicture", inputTexId, 0)
                program.setSamplerTexIdUniform("uMask", maskTexId, 1)
                program.setFloatsUniform("uPictureSize", floatArrayOf(width.toFloat(), height.toFloat()))
                program.setFloatsUniform("uMaskOrigin", placement.origin)
                program.setFloatsUniform("uMaskExtent", placement.extent)
                program.setFloatUniform("uMaskRotation", placement.rotation)
                program.setFloatUniform("uMaskAspect", placement.aspect)
                program.setFloatUniform("uAlpha", alpha)
                if (hidden != null) {
                    // Without a blur pass (alpha 0) the small texture may not
                    // exist yet; the shader never reads it then, but every
                    // sampler has to be bound, so it gets the picture instead.
                    val hiddenTexId = if (alpha > 0f) hidden.texture else inputTexId
                    program.setSamplerTexIdUniform("uHidden", hiddenTexId, 2)
                    program.setFloatsUniform(
                        "uHiddenSize", floatArrayOf(hidden.width.toFloat(), hidden.height.toFloat())
                    )
                    program.setFloatUniform("uScale", hidden.scale.toFloat())
                    program.setFloatUniform("uMargin", hidden.margin.toFloat())
                } else {
                    program.setFloatUniform("uBlock", censor.blockSize.toFloat())
                    program.setFloatsUniform("uAnchor", placement.topLeftPixel(width, height))
                }
                DownscaledGaussian.draw(program)
                // The mask and the blur were bound on later units; hand the
                // first back active.
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e, presentationTimeUs)
            }
        }

        /** Averages the picture into [hidden]'s small texture and blurs it there. */
        private fun blurIntoSmall(hidden: DownscaledGaussian, inputTexId: Int) {
            val sigma = censor.strength
            hidden.beginDownsample(width, height, sigma)
            val downsample = downsampleProgram!!
            downsample.use()
            downsample.setSamplerTexIdUniform("uPicture", inputTexId, 0)
            downsample.setFloatsUniform("uPictureSize", floatArrayOf(width.toFloat(), height.toFloat()))
            downsample.setFloatUniform("uScale", hidden.scale.toFloat())
            downsample.setFloatUniform("uMargin", hidden.margin.toFloat())
            DownscaledGaussian.draw(downsample)
            hidden.blur(sigma)
        }

        override fun release() {
            super.release()
            try {
                hidden?.release()
                // The overlay owns the mask texture, as it would inside an
                // OverlayEffect, whose program releases it the same way.
                mask.release()
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e)
            } finally {
                try {
                    combineProgram.delete()
                    downsampleProgram?.delete()
                } catch (e: Exception) {
                    throw VideoFrameProcessingException(e)
                }
            }
        }
    }

    private companion object {
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
        // uAlpha is 0 whenever the extent may be (see coversFrame), so the
        // division never sees it. A tilted quad is turned back around its
        // center, where v = 0, in units that are as wide as they are tall:
        // uMaskAspect is the quad's width over its height.
        private const val MASK_FUNCTION =
            "uniform sampler2D uMask;\n" +
            "uniform vec2 uMaskOrigin;\n" +
            "uniform vec2 uMaskExtent;\n" +
            "uniform float uMaskRotation;\n" +
            "uniform float uMaskAspect;\n" +
            "uniform float uAlpha;\n" +
            "float maskAt(vec2 p, vec2 size) {\n" +
            "  if (uAlpha <= 0.0) return 0.0;\n" +
            "  vec2 v = (2.0 * p / size - 1.0 - uMaskOrigin) / uMaskExtent;\n" +
            "  if (uMaskRotation != 0.0) {\n" +
            "    float c = cos(uMaskRotation);\n" +
            "    float s = sin(uMaskRotation);\n" +
            "    vec2 q = vec2(v.x * uMaskAspect, v.y);\n" +
            "    v = vec2((c * q.x + s * q.y) / uMaskAspect, c * q.y - s * q.x);\n" +
            "  }\n" +
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
 * A layer's own rotation is not part of it: `prepareOverlay` turns the bitmap
 * itself. The tilt of a wiggle animation is: Media3 turns the quad by
 * [rotation] around its own center, `v = 0`, in units as wide as they are tall,
 * before it is placed. [aspect] is the quad's width over its height in frame
 * pixels, which converts between those units and the quad's.
 */
internal data class CensorMaskPlacement(
    val origin: FloatArray,
    val extent: FloatArray,
    /** Counter-clockwise, in radians. */
    val rotation: Float = 0f,
    val aspect: Float = 1f,
) {

    /**
     * The quad coordinates of the frame point [ndcX], [ndcY] (normalized
     * device coordinates, y up), the same arithmetic as the shader's.
     */
    fun quadCoordinateOf(ndcX: Float, ndcY: Float): Pair<Float, Float> {
        val vx = (ndcX - origin[0]) / extent[0]
        val vy = (ndcY - origin[1]) / extent[1]
        if (rotation == 0f) return vx to vy
        val c = cos(rotation)
        val s = sin(rotation)
        val qx = vx * aspect
        return (c * qx + s * vy) / aspect to c * vy - s * qx
    }

    /**
     * Whether the quad covers any of the frame: not when it is scaled down to
     * nothing, as a scale animation from 0 starts, or lies wholly beyond an
     * edge, as a layer sliding in from off the frame does. A tilted quad is
     * measured by the box around it.
     */
    fun coversFrame(): Boolean {
        if (extent[0] <= 0f || extent[1] <= 0f) return false
        var halfX = extent[0]
        var halfY = extent[1]
        if (rotation != 0f) {
            val c = abs(cos(rotation))
            val s = abs(sin(rotation))
            halfX = extent[0] * (c + s / aspect)
            halfY = extent[1] * (c + s * aspect)
        }
        return origin[0] - halfX < 1f && origin[0] + halfX > -1f &&
            origin[1] - halfY < 1f && origin[1] + halfY > -1f
    }

    /**
     * The quad's top-left corner in whole pixels of a [frameWidth] by
     * [frameHeight] frame, counted from its top-left corner: where a censor
     * layer's pixelate blocks start. The blocks stay upright on a tilted quad,
     * starting at the corner it has untilted.
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
            extent.contentEquals(other.extent) &&
            rotation == other.rotation &&
            aspect == other.aspect

    override fun hashCode(): Int =
        ((31 * origin.contentHashCode() + extent.contentHashCode()) * 31 +
            rotation.hashCode()) * 31 + aspect.hashCode()

    companion object {
        fun of(
            backgroundAnchor: FloatArray,
            overlayAnchor: FloatArray,
            scale: FloatArray,
            maskWidth: Int,
            maskHeight: Int,
            frameWidth: Int,
            frameHeight: Int,
            rotationDegrees: Float = 0f,
        ): CensorMaskPlacement {
            val extent = floatArrayOf(
                maskWidth.toFloat() / frameWidth * scale[0],
                maskHeight.toFloat() / frameHeight * scale[1],
            )
            val origin = floatArrayOf(
                backgroundAnchor[0] - extent[0] * overlayAnchor[0],
                backgroundAnchor[1] - extent[1] * overlayAnchor[1],
            )
            val displayHeight = maskHeight * scale[1]
            val aspect = if (displayHeight > 0f) maskWidth * scale[0] / displayHeight else 1f
            return CensorMaskPlacement(
                origin,
                extent,
                rotation = Math.toRadians(rotationDegrees.toDouble()).toFloat(),
                aspect = aspect,
            )
        }
    }
}
