package ch.waio.pro_video_editor.src.features.render.helpers

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.OverlaySettings
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import ch.waio.pro_video_editor.src.features.render.models.LayerBlendMode

/**
 * An image layer drawn onto the frame composed so far — the video and every
 * image layer before this one — in a [LayerBlendMode] other than
 * [LayerBlendMode.NORMAL], which Media3's `OverlayEffect` cannot draw: it only
 * draws its overlays over the frame.
 *
 * [layer] is the overlay the layer would otherwise be drawn as, so it lands
 * exactly where that overlay would, as a censor layer's mask does (see
 * [LayerCensorEffect]): its position, its size, its rotation (baked into the
 * bitmap by `prepareOverlay`), its animations, including the tilt of a wiggle,
 * and its keyframes. Its alpha, times the overlay's alpha scale, is how much
 * of the blended color replaces the frame. [CensorMaskPlacement] maps the
 * frame onto the overlay's texture.
 */
@UnstableApi
internal class LayerBlendEffect(
    private val layer: BitmapOverlay,
    private val mode: LayerBlendMode,
) : GlEffect {

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
        if (useHdr) {
            // An ES 2.0 SDR program, like the censor and the chroma key.
            // RenderVideo pre-transcodes HDR sources whenever there are image
            // layers, so this guards that gate rather than an expected path.
            throw VideoFrameProcessingException("A blended layer does not support HDR input")
        }
        return BlendShaderProgram(layer, mode)
    }

    @UnstableApi
    private class BlendShaderProgram(
        private val layer: BitmapOverlay,
        mode: LayerBlendMode,
    ) : BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ false, /* texturePoolCapacity= */ 1) {

        private val program = GlProgram(VideoEffectGlow.VERTEX_SHADER, shaderFor(mode))

        private var width = 0
        private var height = 0

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            width = inputWidth
            height = inputHeight
            layer.configure(Size(inputWidth, inputHeight))
            return Size(inputWidth, inputHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            try {
                val settings = layer.getOverlaySettings(presentationTimeUs)
                val layerTexId = layer.getTextureId(presentationTimeUs)
                val layerSize = layer.getTextureSize(presentationTimeUs)
                val placement = CensorMaskPlacement.of(
                    settings.backgroundAnchor(),
                    settings.overlayAnchor(),
                    settings.scaleXY(),
                    maskWidth = layerSize.width,
                    maskHeight = layerSize.height,
                    frameWidth = width,
                    frameHeight = height,
                    rotationDegrees = settings.rotationDegrees,
                )
                // Nothing is drawn while the layer is faded out, scaled down to
                // nothing or wholly off the frame; the shader then copies the
                // frame without dividing by the zero extent.
                val alpha = if (placement.coversFrame()) settings.alphaScale else 0f

                program.use()
                program.setSamplerTexIdUniform("uPicture", inputTexId, 0)
                program.setSamplerTexIdUniform("uLayer", layerTexId, 1)
                program.setFloatsUniform(
                    "uPictureSize", floatArrayOf(width.toFloat(), height.toFloat())
                )
                program.setFloatsUniform("uLayerOrigin", placement.origin)
                program.setFloatsUniform("uLayerExtent", placement.extent)
                program.setFloatUniform("uLayerRotation", placement.rotation)
                program.setFloatUniform("uLayerAspect", placement.aspect)
                program.setFloatUniform("uAlpha", alpha)
                DownscaledGaussian.draw(program)
                // The layer was bound on a later unit; hand the first back
                // active.
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e, presentationTimeUs)
            }
        }

        override fun release() {
            super.release()
            try {
                // The overlay owns its texture, as it would inside an
                // OverlayEffect, whose program releases it the same way.
                layer.release()
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e)
            } finally {
                try {
                    program.delete()
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

        // The layer's color and alpha at a pixel center, in GL's bottom-up
        // pixel space, mapped onto the overlay quad as the censor mask is
        // (see LayerCensorEffect): v = (P - origin) / extent, turned back by
        // a wiggle's tilt in units as wide as they are tall. The texture
        // holds straight alpha (`unpremultiplyAlpha`), as Media3's overlay
        // shader reads it. Outside the quad the layer is not there at all.
        private const val LAYER_FUNCTION =
            "uniform sampler2D uLayer;\n" +
            "uniform vec2 uLayerOrigin;\n" +
            "uniform vec2 uLayerExtent;\n" +
            "uniform float uLayerRotation;\n" +
            "uniform float uLayerAspect;\n" +
            "uniform float uAlpha;\n" +
            "vec4 layerAt(vec2 p, vec2 size) {\n" +
            "  if (uAlpha <= 0.0) return vec4(0.0);\n" +
            "  vec2 v = (2.0 * p / size - 1.0 - uLayerOrigin) / uLayerExtent;\n" +
            "  if (uLayerRotation != 0.0) {\n" +
            "    float c = cos(uLayerRotation);\n" +
            "    float s = sin(uLayerRotation);\n" +
            "    vec2 q = vec2(v.x * uLayerAspect, v.y);\n" +
            "    v = vec2((c * q.x + s * q.y) / uLayerAspect, c * q.y - s * q.x);\n" +
            "  }\n" +
            "  vec2 st = vec2(0.5 * v.x + 0.5, 0.5 - 0.5 * v.y);\n" +
            "  if (st.x < 0.0 || st.x > 1.0 || st.y < 0.0 || st.y > 1.0) return vec4(0.0);\n" +
            "  vec4 color = texture2D(uLayer, st);\n" +
            "  return vec4(color.rgb, color.a * uAlpha);\n" +
            "}\n"

        /** Blends the layer onto the frame in [mode]; see [LayerBlendMode]. */
        fun shaderFor(mode: LayerBlendMode): String = VideoEffectGlow.PRECISION +
            LAYER_FUNCTION +
            LayerBlendShader.FUNCTIONS +
            "uniform sampler2D uPicture;\n" +
            "uniform vec2 uPictureSize;\n" +
            "void main() {\n" +
            "  vec2 p = floor(gl_FragCoord.xy) + 0.5;\n" +
            "  vec4 picture = texture2D(uPicture, p / uPictureSize);\n" +
            "  vec4 layer = layerAt(p, uPictureSize);\n" +
            "  if (layer.a <= 0.0) {\n" +
            "    gl_FragColor = picture;\n" +
            "    return;\n" +
            "  }\n" +
            "  gl_FragColor = ${LayerBlendShader.functionFor(mode)}(picture, layer);\n" +
            "}"
    }
}
