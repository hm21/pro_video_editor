package ch.waio.pro_video_editor.src.features.render.helpers

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.C
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import ch.waio.pro_video_editor.effects.CustomVideoEffectFrame
import ch.waio.pro_video_editor.effects.CustomVideoEffectHistoryFrame
import ch.waio.pro_video_editor.effects.CustomVideoEffectRenderer
import ch.waio.pro_video_editor.effects.CustomVideoEffectShader
import ch.waio.pro_video_editor.effects.CustomVideoEffects
import ch.waio.pro_video_editor.src.features.render.models.CustomVideoEffectConfig
import ch.waio.pro_video_editor.src.features.render.models.VideoEffectConfig
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Runs one custom video effect, whose renderer the app registered with
 * [CustomVideoEffects], on every frame.
 *
 * Outside the effect's time range the frame passes through unchanged. When
 * the renderer asks for earlier frames, each frame is also copied into a
 * history slot, at the renderer's history scale, and handed back on later
 * frames of the same input stream: a clip in a sequence, so the history
 * starts over at every cut.
 *
 * Like [VideoEffectGlEffect] it runs after a clip's own `SpeedChangeEffect`
 * but ahead of a render-wide one, whose speed moves the times it sees to
 * where that effect puts the frame, so the effect's time range and history
 * offsets follow the rendered video.
 */
@UnstableApi
class CustomVideoEffectGlEffect(
    private val config: CustomVideoEffectConfig,
    private val playbackSpeed: Float = 1f,
) : GlEffect {

    /**
     * This effect ahead of one more `SpeedChangeEffect` of [speed], the
     * render-wide one, on top of [playbackSpeed].
     */
    fun withSpeedChange(speed: Float?): CustomVideoEffectGlEffect =
        if (speed == null || speed <= 0f || speed == 1f) this
        else CustomVideoEffectGlEffect(config, playbackSpeed * speed)

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
        if (useHdr) {
            throw VideoFrameProcessingException("Custom video effects do not support HDR input")
        }
        val factory = CustomVideoEffects.factory(config.id)
            ?: throw VideoFrameProcessingException(
                "No custom video effect is registered under \"${config.id}\""
            )
        val renderer = try {
            factory.create(config.params)
        } catch (e: Exception) {
            throw VideoFrameProcessingException(e)
        }
        return CustomVideoEffectShaderProgram(renderer, config, playbackSpeed)
    }

    override fun isNoOp(inputWidth: Int, inputHeight: Int): Boolean = false

    @UnstableApi
    private class CustomVideoEffectShaderProgram(
        private val renderer: CustomVideoEffectRenderer,
        private val config: CustomVideoEffectConfig,
        private val playbackSpeed: Float,
    ) : BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ false, /* texturePoolCapacity= */ 1) {

        private val history = CustomVideoEffectHistory(renderer.historyOffsetsUs)
        private val historyScale = renderer.historyScale.coerceIn(0.05f, 1f)
        private val copy = CustomVideoEffectShader(COPY_SHADER)

        private var width = 0
        private var height = 0
        private var historyWidth = 0
        private var historyHeight = 0

        /** Texture and framebuffer of every history slot, by slot id. */
        private val slotTextures = ArrayList<Int>()
        private val slotFbos = ArrayList<Int>()
        private val freeSlots = ArrayDeque<Int>()

        /** The first timestamp of the current input stream, where a speed change anchors. */
        private var streamStartUs = C.TIME_UNSET

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            if (inputWidth != width || inputHeight != height) {
                history.clear()
                deleteSlots()
                width = inputWidth
                height = inputHeight
                historyWidth = max(1, (inputWidth * historyScale).roundToInt())
                historyHeight = max(1, (inputHeight * historyScale).roundToInt())
                renderer.configure(inputWidth, inputHeight)
            }
            return Size(inputWidth, inputHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            try {
                if (streamStartUs == C.TIME_UNSET) streamStartUs = presentationTimeUs
                val timeUs = VideoEffectConfig.timeAfterSpeedChangeUs(
                    presentationTimeUs, streamStartUs, playbackSpeed
                )
                val outputFbo = VideoEffectGlow.currentFramebuffer()

                if (config.isActiveAt(timeUs)) {
                    val frames = history.lookup(timeUs).map { entry ->
                        entry?.let {
                            CustomVideoEffectHistoryFrame(
                                textureId = slotTextures[it.slot],
                                width = historyWidth,
                                height = historyHeight,
                                timeUs = it.timeUs,
                            )
                        }
                    }
                    renderer.render(
                        CustomVideoEffectFrame(
                            textureId = inputTexId,
                            width = width,
                            height = height,
                            timeUs = timeUs,
                            effectTimeUs = timeUs - (config.startUs ?: 0L),
                            history = frames,
                        )
                    )
                } else {
                    drawCopy(inputTexId)
                }

                if (history.isUsed && config.keepsFrameAt(timeUs, history.maxOffsetUs)) {
                    keep(inputTexId, timeUs)
                    GlUtil.focusFramebufferUsingCurrentContext(outputFbo, width, height)
                }
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                GlUtil.checkGlError()
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e, presentationTimeUs)
            }
        }

        /** Copies the frame into a history slot and records it. */
        private fun keep(inputTexId: Int, timeUs: Long) {
            val slot = freeSlots.removeFirstOrNull() ?: newSlot()
            GlUtil.focusFramebufferUsingCurrentContext(slotFbos[slot], historyWidth, historyHeight)
            drawCopy(inputTexId)
            freeSlots += history.record(timeUs, slot)
        }

        private fun drawCopy(textureId: Int) {
            copy.use()
            copy.setTexture("uTexSampler", textureId, 0)
            copy.draw()
        }

        private fun newSlot(): Int {
            val texture = GlUtil.createTexture(
                historyWidth, historyHeight, /* useHighPrecisionColorComponents= */ false
            )
            slotTextures += texture
            slotFbos += GlUtil.createFboForTexture(texture)
            return slotTextures.size - 1
        }

        private fun deleteSlots() {
            for (fbo in slotFbos) GlUtil.deleteFbo(fbo)
            for (texture in slotTextures) GlUtil.deleteTexture(texture)
            slotFbos.clear()
            slotTextures.clear()
            freeSlots.clear()
        }

        // Every input stream is a clip of its own: its history and speed
        // mapping start over with its first frame.
        override fun signalEndOfCurrentInputStream() {
            super.signalEndOfCurrentInputStream()
            freeSlots += history.clear()
            streamStartUs = C.TIME_UNSET
        }

        override fun flush() {
            super.flush()
            freeSlots += history.clear()
            streamStartUs = C.TIME_UNSET
        }

        override fun release() {
            super.release()
            try {
                try {
                    renderer.release()
                } finally {
                    deleteSlots()
                    copy.release()
                }
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e)
            }
        }

        private companion object {
            // highp keeps the texture coordinate exact enough to land on texel
            // centers of a large frame, so the pass-through copies pixels as
            // they are.
            const val COPY_SHADER =
                "#ifdef GL_FRAGMENT_PRECISION_HIGH\n" +
                "precision highp float;\n" +
                "#else\n" +
                "precision mediump float;\n" +
                "#endif\n" +
                "uniform sampler2D uTexSampler;\n" +
                "varying vec2 vTexCoord;\n" +
                "void main() {\n" +
                "  gl_FragColor = texture2D(uTexSampler, vTexCoord);\n" +
                "}"
        }
    }
}
