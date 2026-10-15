package ch.waio.pro_video_editor.src.features.render.helpers

import android.content.Context
import android.graphics.Bitmap
import android.opengl.GLES20
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import ch.waio.pro_video_editor.src.shared.media.EncodedImage
import ch.waio.pro_video_editor.src.shared.media.ImageOrientation

/**
 * Shapes every frame with an alpha matte: each pixel keeps its own alpha times
 * the matte's alpha there, and the matte's colors are ignored.
 *
 * The matte is stretched over the whole frame. In a layered composition that
 * is the clip's own frame — decoded upright by Media3 and keyed by a chroma key
 * that runs first, but not yet placed on the canvas — so the mask moves,
 * scales and turns with the clip's placement, as the Apple renderer does it.
 *
 * Alpha is **straight**, as everywhere in Media3 (see [ChromaKeyEffect]): the
 * RGB passes through and only the alpha is scaled, and Media3's compositor
 * blends the result over the layers below. Scaling a premultiplied color here
 * as well would darken every soft edge twice.
 *
 * @param image The encoded matte.
 * @param probe The matte's size and EXIF orientation, read once when the
 *  composition was built so a matte that does not decode fails it there.
 */
@UnstableApi
internal class MaskEffect(
    private val image: EncodedImage,
    private val probe: ImageOrientation.Probe,
) : GlEffect {

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
        if (useHdr) {
            // An ES 2.0 SDR program, like the chroma key. RenderVideo
            // pre-transcodes HDR sources whenever a layer has a mask, so this
            // guards that gate rather than an expected path.
            throw VideoFrameProcessingException("A layer mask does not support HDR input")
        }
        return MaskShaderProgram(image, probe)
    }

    @UnstableApi
    private class MaskShaderProgram(
        private val image: EncodedImage,
        private val probe: ImageOrientation.Probe,
    ) : BaseGlShaderProgram(
        /* useHighPrecisionColorComponents= */ false, /* texturePoolCapacity= */ 1
    ) {

        private val glProgram: GlProgram = try {
            GlProgram(VERTEX_SHADER_SOURCE, FRAGMENT_SHADER_SOURCE)
        } catch (e: Exception) {
            throw VideoFrameProcessingException(e)
        }

        /** The matte's texture id, uploaded on the first frame. */
        private var matteTexId: Int = -1

        private var frameWidth = 0
        private var frameHeight = 0

        companion object {
            private const val VERTEX_SHADER_SOURCE =
                "attribute vec4 aFramePosition;\n" +
                "attribute vec4 aTexSamplingCoord;\n" +
                "varying vec2 vTexSamplingCoord;\n" +
                "void main() {\n" +
                "  gl_Position = aFramePosition;\n" +
                "  vTexSamplingCoord = aTexSamplingCoord.xy;\n" +
                "}"

            // highp where the GPU has it: at mediump a sampling coordinate
            // across a 1920 px frame can be off by a pixel or two, which moves
            // the edge of the shape.
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
                // The matte comes from a Bitmap, whose first row
                // GLUtils.texImage2D uploads at t=0, while a frame texture
                // puts t=0 at the bottom. Flip t, as ChromaKeyEffect does for
                // its background, or the shape is drawn upside down.
                "  vec2 matteCoord = vec2(vTexSamplingCoord.x," +
                " 1.0 - vTexSamplingCoord.y);\n" +
                "  float matte = texture2D(uMaskSampler, matteCoord).a;\n" +
                "  gl_FragColor = vec4(src.rgb, src.a * matte);\n" +
                "}"
        }

        /** Pass-through: masking does not change the frame geometry. */
        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            frameWidth = inputWidth
            frameHeight = inputHeight
            return Size(inputWidth, inputHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            try {
                glProgram.use()

                if (matteTexId == -1) {
                    // createTexture uploads the pixels, so nothing needs the
                    // bitmap afterwards.
                    val bitmap = decodeMatte() ?: throw VideoFrameProcessingException(
                        "The layer mask (${image.describe()}) could not be decoded",
                        presentationTimeUs
                    )
                    matteTexId = try {
                        GlUtil.createTexture(bitmap)
                    } finally {
                        bitmap.recycle()
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

                // No glClear and no blending, for the reason ChromaKeyEffect
                // gives: the draw covers the cleared target entirely, and
                // blending against transparent black would square the alpha.
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                GlUtil.checkGlError()
            } catch (e: VideoFrameProcessingException) {
                throw e
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e, presentationTimeUs)
            }
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
         * Decodes the matte, upright and no larger than the frame it is
         * stretched over on either axis, as on iOS and macOS.
         *
         * Pixels beyond the frame's own size would only be thrown away again
         * by the stretch, so they are not kept — which also keeps a
         * camera-sized matte inside `GL_MAX_TEXTURE_SIZE`, above which
         * `GlUtil.createTexture` throws. The decoder only samples down as far
         * as keeps the matte at least the frame's size, and an exact scale
         * does the rest: halving past it, a 2048 px matte would come out at
         * 1024 px for a 1920 px frame and the stretch would blur its edge.
         *
         * Must be called on the GL thread.
         */
        private fun decodeMatte(): Bitmap? {
            val limit = maxTextureSize()
            val maxWidth = if (frameWidth > 0) minOf(frameWidth, limit) else limit
            val maxHeight = if (frameHeight > 0) minOf(frameHeight, limit) else limit
            val sampled = ImageOrientation.decode(
                image,
                reqWidth = maxWidth,
                reqHeight = maxHeight,
                knownOrientation = probe.orientation
            ) ?: return null
            if (sampled.width <= maxWidth && sampled.height <= maxHeight) return sampled

            val scaled = Bitmap.createScaledBitmap(
                sampled,
                minOf(sampled.width, maxWidth),
                minOf(sampled.height, maxHeight),
                /* filter= */ true
            )
            if (scaled !== sampled) sampled.recycle()
            return scaled
        }

        /** The GPU's maximum texture dimension, or a conservative fallback. */
        private fun maxTextureSize(): Int {
            val value = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, value, 0)
            return if (value[0] > 0) value[0] else 2048
        }
    }
}
