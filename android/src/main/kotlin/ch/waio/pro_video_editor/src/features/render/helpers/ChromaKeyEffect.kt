package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.opengl.GLES20
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import ch.waio.pro_video_editor.src.features.render.models.ChromaKeyConfig
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import ch.waio.pro_video_editor.src.shared.media.ImageOrientation

/**
 * Removes a solid-colored background ("green screen") from every frame.
 *
 * Pixels whose chroma sits within [ChromaKeyConfig.similarity] of the key color
 * are removed, with a [ChromaKeyConfig.smoothness]-wide soft edge, and the key's
 * color cast is pulled back out of the pixels that remain
 * ([ChromaKeyConfig.spill]).
 *
 * The removed area becomes, in this order of precedence: the background image,
 * the background color, or transparency. Transparency only means something in
 * the layered path, where Media3's compositor blends the sequences — see
 * `applyChromaKey`, which substitutes opaque black on the single-track path so
 * both platforms agree.
 *
 * The formula is specified once and implemented twice; see [ChromaKeyMath],
 * which this shader mirrors and which the unit tests pin against the Swift
 * implementation.
 *
 * Alpha is **straight**, not premultiplied — that is Media3's convention
 * throughout (`AlphaScale`, the LUT shader, and `DefaultCompositorGlProgram`'s
 * `glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)`).
 * Apple's color cube stores premultiplied entries instead, because that is what
 * `CIColorCube` requires. Both are correct for their platform; do not align them.
 */
@UnstableApi
class ChromaKeyEffect(private val config: ChromaKeyConfig) : GlEffect {

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
        if (useHdr) {
            // The shader is an ES 2.0 SDR program. HEVC 10-bit/HDR sources are
            // pre-transcoded to 8-bit SDR by VideoTranscoder before they reach
            // here — `RenderVideo.hasGpuEffects` detects a key at every level it
            // can be set, and the transcode step rewrites both `videoClips` and
            // every composition layer's clips. So this is a guard against that
            // gate regressing rather than an expected path.
            throw VideoFrameProcessingException(
                "Chroma key does not support HDR input"
            )
        }
        return ChromaKeyShaderProgram(useHdr, config)
    }

    @UnstableApi
    private class ChromaKeyShaderProgram(
        useHdr: Boolean,
        private val config: ChromaKeyConfig
    ) : BaseGlShaderProgram(useHdr, /* texturePoolCapacity= */ 1) {

        private val glProgram: GlProgram

        /**
         * Bounds-only probe of the background image.
         *
         * Decoding just the header tells us whether the bytes are usable — and
         * how large they are once their EXIF orientation is honored — without
         * holding a full-size bitmap from construction until the first draw. The
         * real decode happens in [drawFrame], where there is a GL context to
         * size it against.
         */
        private val backgroundProbe: ImageOrientation.Probe? =
            config.backgroundImageData?.let { ImageOrientation.probe(it) }

        /**
         * Background texture id. A 1x1 placeholder is uploaded when there is no
         * background image, because Media3's [GlProgram] requires every sampler
         * uniform to be bound before a draw.
         */
        private var backgroundTexId: Int = -1

        private val bgMode: Int = when {
            backgroundProbe != null -> BG_IMAGE
            config.backgroundColor != null -> BG_COLOR
            // An image was asked for but its bytes will not decode. Falling
            // through to BG_TRANSPARENT would quietly un-key the clip on the
            // single-track path, where `applyChromaKey` has already ruled that
            // the area must be filled — the export would come out looking like
            // the key never ran. Fill with opaque black instead, which is what
            // Apple produces in the same situation.
            config.backgroundImageData != null -> BG_COLOR
            else -> BG_TRANSPARENT
        }

        companion object {
            private const val BG_TRANSPARENT = 0
            private const val BG_COLOR = 1
            private const val BG_IMAGE = 2

            private const val VERTEX_SHADER_SOURCE =
                "attribute vec4 aFramePosition;\n" +
                "attribute vec4 aTexSamplingCoord;\n" +
                "varying vec2 vTexSamplingCoord;\n" +
                "void main() {\n" +
                "  gl_Position = aFramePosition;\n" +
                "  vTexSamplingCoord = aTexSamplingCoord.xy;\n" +
                "}"

            // highp matters here: the Cb/Cr deltas the key discriminates are on
            // the order of 1e-3, and mediump only guarantees ~10 mantissa bits.
            private const val FRAGMENT_SHADER_SOURCE =
                "#ifdef GL_FRAGMENT_PRECISION_HIGH\n" +
                "precision highp float;\n" +
                "#else\n" +
                "precision mediump float;\n" +
                "#endif\n" +
                "uniform sampler2D uTexSampler;\n" +
                "uniform sampler2D uBgSampler;\n" +
                "uniform vec2 uKeyCbCr;\n" +
                "uniform vec2 uKeyDir;\n" +
                "uniform float uSimilarity;\n" +
                "uniform float uSmoothness;\n" +
                "uniform float uSpill;\n" +
                "uniform vec3 uBgColor;\n" +
                "uniform int uBgMode;\n" +
                "varying vec2 vTexSamplingCoord;\n" +
                "void main() {\n" +
                "  vec4 src = texture2D(uTexSampler, vTexSamplingCoord);\n" +
                "  vec3 rgb = src.rgb;\n" +
                // BT.601 luma and chroma, matching ChromaKeyMath exactly.
                "  float y = dot(rgb, vec3(0.299, 0.587, 0.114));\n" +
                "  vec2 cbcr = vec2(\n" +
                "      dot(rgb, vec3(-0.168736, -0.331264, 0.5)),\n" +
                "      dot(rgb, vec3(0.5, -0.418688, -0.081312)));\n" +
                // Matte: distance in the chroma plane, ramped by smoothstep.
                "  float d = distance(cbcr, uKeyCbCr);\n" +
                "  float a = smoothstep(uSimilarity," +
                " uSimilarity + max(uSmoothness, 1e-4), d);\n" +
                // Spill: remove the chroma component pointing at the key hue,
                // keeping y so a despilled pixel never darkens. Only pixels
                // leaning toward the key (projection > 0) are touched.
                "  float projection = dot(cbcr, uKeyDir);\n" +
                "  if (uSpill > 0.0 && projection > 0.0) {\n" +
                "    vec2 c = cbcr - uKeyDir * projection * uSpill;\n" +
                "    rgb = clamp(vec3(\n" +
                "        y + 1.402 * c.y,\n" +
                "        y - 0.344136 * c.x - 0.714136 * c.y,\n" +
                "        y + 1.772 * c.x), 0.0, 1.0);\n" +
                "  }\n" +
                // Fold in the frame's own alpha, so an already-transparent
                // pixel (a gap frame carrying AlphaScale(0)) stays transparent.
                "  float outA = src.a * a;\n" +
                "  if (uBgMode == 2) {\n" +
                // The background comes from a Bitmap, and GLUtils.texImage2D
                // uploads its first row at t=0, while a frame texture puts t=0
                // at the *bottom* of the frame. Sampling the bitmap with the
                // frame's own coordinate would show it upside down, so flip t
                // here — the same correction Media3's BitmapOverlay applies via
                // its flipVerticallyMatrix.
                "    vec2 bgCoord = vec2(vTexSamplingCoord.x," +
                " 1.0 - vTexSamplingCoord.y);\n" +
                "    vec3 bg = texture2D(uBgSampler, bgCoord).rgb;\n" +
                "    gl_FragColor = vec4(mix(bg, rgb, outA), src.a);\n" +
                "  } else if (uBgMode == 1) {\n" +
                "    gl_FragColor = vec4(mix(uBgColor, rgb, outA), src.a);\n" +
                "  } else {\n" +
                "    gl_FragColor = vec4(rgb, outA);\n" +
                "  }\n" +
                "}"
        }

        init {
            if (backgroundProbe == null && config.backgroundImageData != null) {
                Log.w(
                    RENDER_TAG,
                    "Chroma key: the background image could not be decoded; " +
                        "filling the keyed area with opaque black instead"
                )
            }
            try {
                glProgram = GlProgram(VERTEX_SHADER_SOURCE, FRAGMENT_SHADER_SOURCE)
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e)
            }
        }

        /** Pass-through: keying does not change the frame geometry. */
        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            return Size(inputWidth, inputHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            try {
                glProgram.use()

                if (backgroundTexId == -1) {
                    // createTexture uploads the pixels, so nothing needs the
                    // bitmap afterwards — including the placeholder, which used
                    // to be allocated and then dropped on the floor.
                    val bitmap = decodeBackgroundWithinTextureLimit()
                        ?: onePixelPlaceholder()
                    backgroundTexId = GlUtil.createTexture(bitmap)
                    bitmap.recycle()
                }

                glProgram.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
                glProgram.setSamplerTexIdUniform("uBgSampler", backgroundTexId, 1)

                glProgram.setFloatsUniform(
                    "uKeyCbCr",
                    floatArrayOf(config.keyCb.toFloat(), config.keyCr.toFloat())
                )
                glProgram.setFloatsUniform(
                    "uKeyDir",
                    floatArrayOf(config.keyDirCb.toFloat(), config.keyDirCr.toFloat())
                )
                glProgram.setFloatUniform("uSimilarity", config.similarity.toFloat())
                glProgram.setFloatUniform("uSmoothness", config.smoothness.toFloat())
                glProgram.setFloatUniform("uSpill", config.spill.toFloat())
                glProgram.setFloatsUniform("uBgColor", backgroundColorRgb())
                glProgram.setIntUniform("uBgMode", bgMode)

                val vertexData = GlUtil.getNormalizedCoordinateBounds()
                glProgram.setBufferAttribute(
                    "aFramePosition", vertexData, if (vertexData.size == 8) 2 else 4
                )
                val texData = GlUtil.getTextureCoordinateBounds()
                glProgram.setBufferAttribute(
                    "aTexSamplingCoord", texData, if (texData.size == 8) 2 else 4
                )

                glProgram.bindAttributesAndUniforms()

                // No glClear and no blending: BaseGlShaderProgram already
                // cleared the target to (0,0,0,0) and this draw covers it
                // entirely, so the fragment output must simply replace it.
                // Blending here would blend against transparent black and
                // square the alpha. The one real blend is Media3's own
                // compositor, which uses glBlendFuncSeparate.
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                GlUtil.checkGlError()
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e, presentationTimeUs)
            }
        }

        override fun release() {
            super.release()
            try {
                if (backgroundTexId != -1) {
                    GlUtil.deleteTexture(backgroundTexId)
                    backgroundTexId = -1
                }
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e)
            } finally {
                // Deleting the texture can throw, and the program still has to
                // go — otherwise a failure on the way out leaks it.
                try {
                    glProgram.delete()
                } catch (e: Exception) {
                    throw VideoFrameProcessingException(e)
                }
            }
        }

        /**
         * Decodes the background image, downscaled to fit `GL_MAX_TEXTURE_SIZE`.
         *
         * A camera photo easily exceeds the 4096 (or 2048) px limit a mid-range
         * GPU reports, and `GlUtil.createTexture` throws above it — which inside
         * [drawFrame] kills the whole export on its first frame. The shader
         * stretches the texture to the frame anyway, so the extra resolution was
         * never going to survive; dropping it here costs nothing.
         *
         * Must be called on the GL thread.
         */
        private fun decodeBackgroundWithinTextureLimit(): Bitmap? {
            val bytes = config.backgroundImageData ?: return null
            val probe = backgroundProbe ?: return null

            val limit = maxTextureSize()
            var sampleSize = 1
            // `probe` is oriented and `inSampleSize` applies to the stored pixels,
            // but an orientation only ever exchanges the two dimensions, so the
            // pair is over the limit either way round.
            while (probe.width / sampleSize > limit || probe.height / sampleSize > limit) {
                sampleSize *= 2
            }

            val raw = BitmapFactory.decodeByteArray(
                bytes, 0, bytes.size,
                BitmapFactory.Options().apply { inSampleSize = sampleSize }
            ) ?: return null

            // A portrait photo is stored as landscape pixels plus an EXIF tag;
            // without this the background would be keyed in sideways.
            val decoded = ImageOrientation.orient(raw, probe.orientation)

            // inSampleSize only halves, so one more exact pass may be needed.
            if (decoded.width <= limit && decoded.height <= limit) return decoded
            val scale = minOf(
                limit.toFloat() / decoded.width,
                limit.toFloat() / decoded.height
            )
            val scaled = Bitmap.createScaledBitmap(
                decoded,
                (decoded.width * scale).toInt().coerceAtLeast(1),
                (decoded.height * scale).toInt().coerceAtLeast(1),
                /* filter= */ true
            )
            if (scaled !== decoded) decoded.recycle()
            return scaled
        }

        /** The GPU's maximum texture dimension, or a conservative fallback. */
        private fun maxTextureSize(): Int {
            val value = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, value, 0)
            return if (value[0] > 0) value[0] else 2048
        }

        /** The background color as linear-free RGB in 0..1, or black. */
        private fun backgroundColorRgb(): FloatArray {
            val argb = config.backgroundColor ?: return floatArrayOf(0f, 0f, 0f)
            return floatArrayOf(
                ((argb shr 16) and 0xFF) / 255f,
                ((argb shr 8) and 0xFF) / 255f,
                (argb and 0xFF) / 255f
            )
        }

        /**
         * A 1x1 transparent texture, bound to `uBgSampler` when there is no
         * background image so the sampler uniform is never left unbound.
         */
        private fun onePixelPlaceholder(): Bitmap =
            Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888).apply {
                eraseColor(android.graphics.Color.TRANSPARENT)
            }
    }
}
