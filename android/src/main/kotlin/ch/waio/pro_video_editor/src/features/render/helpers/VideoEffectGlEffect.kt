package ch.waio.pro_video_editor.src.features.render.helpers

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.C
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import ch.waio.pro_video_editor.src.features.render.models.VideoEffectConfig
import ch.waio.pro_video_editor.src.features.render.models.VideoEffectFrame

/**
 * Applies the video effects (glitch, VHS, old film, …) to every frame.
 *
 * Each frame's `presentationTimeUs` picks the active [VideoEffectFrame] of
 * every effect ([VideoEffectConfig.resolve]); the fragment shader then applies
 * it. The shader implements [VideoEffectMath]: after the geometry every size
 * is rounded to whole pixels, so each step copies whole texels and nothing is
 * interpolated, and the geometry stages filter bilinearly in float math,
 * which is what lets Apple's Core Image stage produce the same pixels.
 *
 * The effect runs ahead of a clip's `SpeedChangeEffect`, so a clip with a
 * [playbackSpeed] hands it timestamps from before the speed change. They are
 * moved to where that effect puts the frame, so the effects follow the
 * rendered video, as on iOS and in the preview, and a flashing effect keeps
 * its rate on a sped-up clip.
 */
@UnstableApi
class VideoEffectGlEffect(
    private val effects: List<VideoEffectConfig>,
    private val playbackSpeed: Float = 1f,
) : GlEffect {

    /**
     * This effect ahead of one more `SpeedChangeEffect` of [speed], on top of
     * [playbackSpeed]: a clip's own speed, or the render-wide one.
     */
    fun withSpeedChange(speed: Float?): VideoEffectGlEffect =
        if (speed == null || speed <= 0f || speed == 1f) this
        else VideoEffectGlEffect(effects, playbackSpeed * speed)

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
        if (useHdr) {
            // An ES 2.0 SDR program, like the chroma key. HEVC 10-bit/HDR
            // sources are pre-transcoded to SDR first because
            // `RenderVideo.hasGpuEffects` counts effects; this guards that gate.
            throw VideoFrameProcessingException("Video effects do not support HDR input")
        }
        return VideoEffectShaderProgram(useHdr, effects, playbackSpeed)
    }

    override fun isNoOp(inputWidth: Int, inputHeight: Int): Boolean = effects.isEmpty()

    @UnstableApi
    private class VideoEffectShaderProgram(
        useHdr: Boolean,
        private val effects: List<VideoEffectConfig>,
        private val playbackSpeed: Float,
    ) : BaseGlShaderProgram(useHdr, /* texturePoolCapacity= */ 1) {

        private val glProgram: GlProgram
        private var width = 0
        private var height = 0

        /** The first timestamp of the current input stream, where a speed change anchors. */
        private var streamStartUs = C.TIME_UNSET

        init {
            try {
                glProgram = GlProgram(VERTEX_SHADER_SOURCE, FRAGMENT_SHADER_SOURCE)
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e)
            }
        }

        /** Pass-through: the effects do not change the frame geometry. */
        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            width = inputWidth
            height = inputHeight
            return Size(inputWidth, inputHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            try {
                if (streamStartUs == C.TIME_UNSET) streamStartUs = presentationTimeUs
                val timelineUs = VideoEffectConfig.timeAfterSpeedChangeUs(
                    presentationTimeUs, streamStartUs, playbackSpeed
                )
                val frame = VideoEffectConfig.resolve(effects, timelineUs)
                glProgram.use()
                glProgram.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
                glProgram.setFloatsUniform(
                    "uSize", floatArrayOf(width.toFloat(), height.toFloat())
                )
                setFrameUniforms(frame)

                val vertexData = GlUtil.getNormalizedCoordinateBounds()
                glProgram.setBufferAttribute(
                    "aFramePosition", vertexData, if (vertexData.size == 8) 2 else 4
                )
                glProgram.bindAttributesAndUniforms()

                // No blending: the draw covers the cleared target entirely.
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                GlUtil.checkGlError()
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e, presentationTimeUs)
            }
        }

        private fun setFrameUniforms(frame: VideoEffectFrame) {
            glProgram.setFloatUniform("uPixelSize", frame.pixelSize.toFloat())
            glProgram.setFloatUniform("uRgbShift", frame.rgbShift.toFloat())
            glProgram.setFloatUniform("uScanlines", frame.scanlines.toFloat())
            glProgram.setFloatUniform("uScanlinePeriod", frame.scanlinePeriod.toFloat())
            glProgram.setFloatUniform("uNoise", frame.noise.toFloat())
            glProgram.setFloatUniform("uNoiseCellSize", frame.noiseCellSize.toFloat())
            glProgram.setFloatsUniform(
                "uNoiseOffset",
                floatArrayOf(frame.noiseOffsetX.toFloat(), frame.noiseOffsetY.toFloat()),
            )
            val bands = frame.bands.take(VideoEffectFrame.MAX_BANDS)
            glProgram.setFloatUniform("uBandCount", bands.size.toFloat())
            for (i in 0 until VideoEffectFrame.MAX_BANDS) {
                val band = bands.getOrNull(i)
                glProgram.setFloatsUniform(
                    "uBand$i",
                    floatArrayOf(
                        band?.top?.toFloat() ?: 0f,
                        band?.bottom?.toFloat() ?: 0f,
                        band?.shift?.toFloat() ?: 0f,
                    ),
                )
            }
            glProgram.setFloatUniform("uSepia", frame.sepia.toFloat())
            glProgram.setFloatUniform("uBrightness", frame.brightness.toFloat())
            glProgram.setFloatUniform("uInvert", frame.invert.toFloat())
            glProgram.setFloatUniform("uFlash", frame.flash.toFloat())
            glProgram.setFloatUniform("uVignette", frame.vignette.toFloat())
            glProgram.setFloatUniform("uVignetteRadius", frame.vignetteRadius.toFloat())
            glProgram.setFloatUniform("uZoom", frame.zoom.toFloat())
            glProgram.setFloatsUniform(
                "uOffset", floatArrayOf(frame.offsetX.toFloat(), frame.offsetY.toFloat())
            )
            glProgram.setFloatsUniform(
                "uMirror", floatArrayOf(frame.mirrorX.toFloat(), frame.mirrorY.toFloat())
            )
            glProgram.setFloatUniform("uTiles", frame.tiles.toFloat())
            glProgram.setFloatsUniform(
                "uWave",
                floatArrayOf(
                    frame.waveAmplitude.toFloat(),
                    frame.wavePeriod.toFloat(),
                    frame.wavePhase.toFloat(),
                ),
            )
        }

        // A speed change starts over from the first frame of every input
        // stream, and so does this effect's mapping.
        override fun signalEndOfCurrentInputStream() {
            super.signalEndOfCurrentInputStream()
            streamStartUs = C.TIME_UNSET
        }

        override fun flush() {
            super.flush()
            streamStartUs = C.TIME_UNSET
        }

        override fun release() {
            super.release()
            try {
                glProgram.delete()
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e)
            }
        }

        companion object {
            private const val VERTEX_SHADER_SOURCE =
                "attribute vec4 aFramePosition;\n" +
                "void main() {\n" +
                "  gl_Position = aFramePosition;\n" +
                "}"

            // highp matters: whole-number arithmetic in floats is exact only
            // below 2^24, and mediump would already fail at 2048.
            //
            // A frame texture puts t=0 at the bottom, while the spec counts rows
            // from the top, so rows are flipped on the way in and out.
            //
            // The bilinear helpers and the three channel reads loop rather than
            // repeat themselves: written out, every geometry stage would be
            // inlined once per call of the one above it, sixty-four times over.
            // `idiv`/`imod` add half a unit before dividing so an approximate GPU
            // division cannot put a quotient on the wrong side of an integer.
            private const val FRAGMENT_SHADER_SOURCE =
                "#ifdef GL_FRAGMENT_PRECISION_HIGH\n" +
                "precision highp float;\n" +
                "#else\n" +
                "precision mediump float;\n" +
                "#endif\n" +
                "uniform sampler2D uTexSampler;\n" +
                "uniform vec2 uSize;\n" +
                "uniform float uPixelSize;\n" +
                "uniform float uRgbShift;\n" +
                "uniform float uScanlines;\n" +
                "uniform float uScanlinePeriod;\n" +
                "uniform float uNoise;\n" +
                "uniform float uNoiseCellSize;\n" +
                "uniform vec2 uNoiseOffset;\n" +
                "uniform float uBandCount;\n" +
                "uniform vec3 uBand0;\n" +
                "uniform vec3 uBand1;\n" +
                "uniform vec3 uBand2;\n" +
                "uniform vec3 uBand3;\n" +
                "uniform float uSepia;\n" +
                "uniform float uBrightness;\n" +
                "uniform float uInvert;\n" +
                "uniform float uFlash;\n" +
                "uniform float uVignette;\n" +
                "uniform float uVignetteRadius;\n" +
                "uniform float uZoom;\n" +
                "uniform vec2 uOffset;\n" +
                "uniform vec2 uMirror;\n" +
                "uniform float uTiles;\n" +
                "uniform vec3 uWave;\n" +
                "float toPixels(float f, float size) { return floor(f * size + 0.5); }\n" +
                "float idiv(float a, float b) { return floor((a + 0.5) / b); }\n" +
                "float imod(float a, float b) { return a - b * idiv(a, b); }\n" +
                "float noiseAt(float u, float v) {\n" +
                "  float a = imod(u * 37.0 + v * 101.0 + 13.0, 251.0);\n" +
                "  a = imod(a * a + u * 7.0 + 17.0, 251.0);\n" +
                "  a = imod(a * a + v * 3.0 + 29.0, 251.0);\n" +
                "  return a / 251.0;\n" +
                "}\n" +
                "vec4 source(vec2 texel) {\n" +
                "  texel = clamp(texel, vec2(0.0), uSize - 1.0);\n" +
                "  vec2 uv = vec2((texel.x + 0.5) / uSize.x, 1.0 - (texel.y + 0.5) / uSize.y);\n" +
                "  return texture2D(uTexSampler, uv);\n" +
                "}\n" +
                "vec4 sourceAt(vec2 p) {\n" +
                "  vec2 t = p - 0.5;\n" +
                "  vec2 i = floor(t);\n" +
                "  vec2 f = t - i;\n" +
                "  vec4 sum = vec4(0.0);\n" +
                "  for (int n = 0; n < 4; n++) {\n" +
                "    vec2 o = vec2(float(n - 2 * (n / 2)), float(n / 2));\n" +
                "    vec2 w = mix(1.0 - f, f, o);\n" +
                "    if (w.x * w.y > 0.0) sum += w.x * w.y * source(i + o);\n" +
                "  }\n" +
                "  return sum;\n" +
                "}\n" +
                "float waveShift(float y) {\n" +
                "  float period = max(uWave.y, 0.1) * uSize.y;\n" +
                "  float t = (y / period + uWave.z) * 16.0;\n" +
                "  float k = floor(t);\n" +
                "  float from = sin(6.283185307179586 * k / 16.0);\n" +
                "  float to = sin(6.283185307179586 * (k + 1.0) / 16.0);\n" +
                "  return uWave.x * uSize.x * (from + (to - from) * (t - k));\n" +
                "}\n" +
                "vec4 waved(vec2 texel) {\n" +
                "  if (uWave.x == 0.0 || uWave.y <= 0.0) return source(texel);\n" +
                "  texel = clamp(texel, vec2(0.0), uSize - 1.0);\n" +
                "  return sourceAt(vec2(texel.x + 0.5 - waveShift(texel.y + 0.5), texel.y + 0.5));\n" +
                "}\n" +
                "vec4 wavedAt(vec2 p) {\n" +
                "  vec2 t = p - 0.5;\n" +
                "  vec2 i = floor(t);\n" +
                "  vec2 f = t - i;\n" +
                "  vec4 sum = vec4(0.0);\n" +
                "  for (int n = 0; n < 4; n++) {\n" +
                "    vec2 o = vec2(float(n - 2 * (n / 2)), float(n / 2));\n" +
                "    vec2 w = mix(1.0 - f, f, o);\n" +
                "    if (w.x * w.y > 0.0) sum += w.x * w.y * waved(i + o);\n" +
                "  }\n" +
                "  return sum;\n" +
                "}\n" +
                "vec4 transformed(vec2 texel) {\n" +
                "  if (uZoom <= 0.0 && uOffset == vec2(0.0) && uMirror.x <= 0.0 && uMirror.y <= 0.0) {\n" +
                "    return waved(texel);\n" +
                "  }\n" +
                "  texel = clamp(texel, vec2(0.0), uSize - 1.0);\n" +
                "  vec2 mirrored = min(\n" +
                "      vec2(toPixels(uMirror.x, uSize.x), toPixels(uMirror.y, uSize.y)), floor(uSize / 2.0));\n" +
                "  vec2 axis = uSize - mirrored;\n" +
                "  if (uMirror.x > 0.0 && texel.x >= axis.x) texel.x = 2.0 * axis.x - 1.0 - texel.x;\n" +
                "  if (uMirror.y > 0.0 && texel.y >= axis.y) texel.y = 2.0 * axis.y - 1.0 - texel.y;\n" +
                "  vec2 c = uSize / 2.0;\n" +
                "  return wavedAt((texel + 0.5 - c - uOffset * uSize) / (1.0 + max(uZoom, 0.0)) + c);\n" +
                "}\n" +
                "vec4 transformedAt(vec2 p) {\n" +
                "  vec2 t = p - 0.5;\n" +
                "  vec2 i = floor(t);\n" +
                "  vec2 f = t - i;\n" +
                "  vec4 sum = vec4(0.0);\n" +
                "  for (int n = 0; n < 4; n++) {\n" +
                "    vec2 o = vec2(float(n - 2 * (n / 2)), float(n / 2));\n" +
                "    vec2 w = mix(1.0 - f, f, o);\n" +
                "    if (w.x * w.y > 0.0) sum += w.x * w.y * transformed(i + o);\n" +
                "  }\n" +
                "  return sum;\n" +
                "}\n" +
                "vec4 picture(vec2 texel) {\n" +
                "  if (uTiles < 1.5) return transformed(texel);\n" +
                "  texel = clamp(texel, vec2(0.0), uSize - 1.0);\n" +
                "  vec2 doubled = texel * 2.0 + 1.0;\n" +
                "  return transformedAt(vec2(imod(doubled.x, uSize.x), imod(doubled.y, uSize.y)));\n" +
                "}\n" +
                "vec4 pixelated(float x, float y) {\n" +
                "  x = clamp(x, 0.0, uSize.x - 1.0);\n" +
                "  float block = toPixels(uPixelSize, uSize.x);\n" +
                "  if (block >= 2.0) {\n" +
                "    float center = floor(block / 2.0);\n" +
                "    x = idiv(x, block) * block + center;\n" +
                "    y = idiv(y, block) * block + center;\n" +
                "  }\n" +
                "  return picture(vec2(x, y));\n" +
                "}\n" +
                "vec4 banded(float x, float y, float shift) {\n" +
                "  x = clamp(x, 0.0, uSize.x - 1.0);\n" +
                "  return pixelated(clamp(x - shift, 0.0, uSize.x - 1.0), y);\n" +
                "}\n" +
                "bool covers(vec3 band, float y) {\n" +
                "  return y >= toPixels(band.x, uSize.y) && y < toPixels(band.y, uSize.y);\n" +
                "}\n" +
                "void main() {\n" +
                "  vec2 p = vec2(floor(gl_FragCoord.x), uSize.y - 1.0 - floor(gl_FragCoord.y));\n" +
                "  float shift = 0.0;\n" +
                "  if (uBandCount > 3.5 && covers(uBand3, p.y)) shift = toPixels(uBand3.z, uSize.x);\n" +
                "  if (uBandCount > 2.5 && covers(uBand2, p.y)) shift = toPixels(uBand2.z, uSize.x);\n" +
                "  if (uBandCount > 1.5 && covers(uBand1, p.y)) shift = toPixels(uBand1.z, uSize.x);\n" +
                "  if (uBandCount > 0.5 && covers(uBand0, p.y)) shift = toPixels(uBand0.z, uSize.x);\n" +
                "  float split = toPixels(uRgbShift, uSize.x);\n" +
                "  vec4 center = vec4(0.0);\n" +
                "  vec3 rgb = vec3(0.0);\n" +
                "  for (int k = 0; k < 3; k++) {\n" +
                "    if (k > 0 && split == 0.0) break;\n" +
                "    vec4 c = banded(p.x + (k == 1 ? split : (k == 2 ? -split : 0.0)), p.y, shift);\n" +
                "    if (k == 0) {\n" +
                "      center = c;\n" +
                "      rgb = c.rgb;\n" +
                "    } else if (k == 1) {\n" +
                "      rgb.r = c.r;\n" +
                "    } else {\n" +
                "      rgb.b = c.b;\n" +
                "    }\n" +
                "  }\n" +

                "  if (uScanlines > 0.0) {\n" +
                "    float period = max(2.0, toPixels(uScanlinePeriod, uSize.y));\n" +
                "    if (imod(p.y, period) * 2.0 >= period) rgb *= 1.0 - uScanlines;\n" +
                "  }\n" +
                "  if (uNoise > 0.0) {\n" +
                "    float cell = max(1.0, toPixels(uNoiseCellSize, uSize.y));\n" +
                "    float u = imod(idiv(p.x, cell) + uNoiseOffset.x, 128.0);\n" +
                "    float v = imod(idiv(p.y, cell) + uNoiseOffset.y, 128.0);\n" +
                "    rgb += (noiseAt(u, v) - 0.5) * uNoise;\n" +
                "  }\n" +
                "  rgb = clamp(rgb, 0.0, 1.0);\n" +
                "  if (uSepia > 0.0) {\n" +
                "    vec3 sepia = vec3(\n" +
                "        dot(rgb, vec3(0.393, 0.769, 0.189)),\n" +
                "        dot(rgb, vec3(0.349, 0.686, 0.168)),\n" +
                "        dot(rgb, vec3(0.272, 0.534, 0.131)));\n" +
                "    rgb = mix(rgb, sepia, uSepia);\n" +
                "  }\n" +
                "  rgb *= 1.0 + uBrightness;\n" +
                "  rgb += uInvert * (1.0 - 2.0 * rgb);\n" +
                "  rgb += uFlash * (1.0 - rgb);\n" +
                "  rgb = clamp(rgb, 0.0, 1.0);\n" +
                "  if (uVignette > 0.0) {\n" +
                "    float radius = clamp(uVignetteRadius, 0.0, 0.99);\n" +
                "    vec2 d = (2.0 * p + 1.0) / uSize - 1.0;\n" +
                "    float t = clamp((sqrt(dot(d, d) / 2.0) - radius) / (1.0 - radius), 0.0, 1.0);\n" +
                "    rgb *= 1.0 - uVignette * t * t;\n" +
                "  }\n" +
                "  gl_FragColor = vec4(clamp(rgb, 0.0, 1.0), center.a);\n" +
                "}"
        }
    }
}
