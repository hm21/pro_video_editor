package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.opengl.EGL14
import android.opengl.EGLContext
import android.opengl.GLES20
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import ch.waio.pro_video_editor.src.features.render.models.LayerBlendMode
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.util.TreeMap

/**
 * Draws the video layers of a layered composition from the lowest one with a
 * [LayerBlendMode] other than [LayerBlendMode.NORMAL] up, which Media3's
 * compositor cannot: `DefaultVideoCompositor` draws every sequence over the
 * ones below it with a fixed `glBlendFuncSeparate`, and Transformer takes no
 * other compositor.
 *
 * Those layers are taken out of the compositor instead. Each of their frames,
 * placed on the canvas as usual by its clip's effects (chroma key, mask,
 * placement, keyframes and opacity), is copied by the [captureEffect] at the
 * end of its chain, which hands the compositor a transparent frame in its
 * place. The compositor composes the layers below, and the [compositeEffect],
 * the first of the composition's own effects, draws the captured frames onto
 * that in z-order, one [modes] entry per captured layer: a normal one over
 * what is there, a blended one onto it (see [LayerBlendShader]). A normal
 * layer above a blended one is captured too, so it still covers it.
 *
 * Media3 runs the frame processor of every sequence, the compositor and the
 * composition's processor on one GL thread with one shared context
 * (`MultipleInputVideoGraph`'s shared executor and its
 * `SingleContextGlObjectsProvider`), so a texture captured in one sequence's
 * chain can be read where the composed frame is drawn. Should a frame arrive
 * in another context, the frames captured in the old one are forgotten
 * rather than read there.
 *
 * Which captured frame goes with a composed one is what the compositor would
 * have chosen: the one of that layer closest in time, see [CapturedTimeline].
 */
@UnstableApi
internal class CapturedVideoLayers(private val modes: List<LayerBlendMode>) {

    init {
        require(modes.isNotEmpty()) { "Nothing to capture" }
    }

    /** How many layers are captured, the slots [captureEffect] takes. */
    val slotCount: Int get() = modes.size

    /**
     * The last effect of every clip item of the captured layer [slot] (from
     * `0`, the lowest captured layer): copies the placed frame and passes a
     * transparent one on.
     */
    fun captureEffect(slot: Int): GlEffect = CaptureEffect(this, slot, copies = true)

    /**
     * The last effect of a transparent gap item of the captured layer [slot]:
     * records that the layer shows nothing at that time, without copying the
     * frame it knows to be transparent.
     */
    fun gapCaptureEffect(slot: Int): GlEffect = CaptureEffect(this, slot, copies = false)

    /** The composition effect that draws the captured layers; see the class. */
    fun compositeEffect(): GlEffect = CompositeEffect(this)

    /** A captured frame: its texture, with the framebuffer that draws into it. */
    private class Frame(val texId: Int, val fboId: Int)

    private val timelines = List(modes.size) { CapturedTimeline<Frame?>() }
    private val free = ArrayDeque<Frame>()
    private var context: EGLContext? = null
    private var frameWidth = 0
    private var frameHeight = 0
    private var copyProgram: GlProgram? = null

    /**
     * Records the frame of [slot] at [presentationTimeUs]: a copy of the
     * [width] by [height] texture [inputTexId] when [copies], or nothing to
     * draw otherwise.
     */
    private fun capture(
        slot: Int,
        presentationTimeUs: Long,
        inputTexId: Int,
        width: Int,
        height: Int,
        copies: Boolean,
    ) {
        ensureContext()
        val frame = if (copies) {
            val target = obtain(width, height)
            GlUtil.focusFramebufferUsingCurrentContext(target.fboId, width, height)
            val program = copyProgram ?: GlProgram(
                VideoEffectGlow.VERTEX_SHADER, COPY_SHADER
            ).also { copyProgram = it }
            program.use()
            program.setSamplerTexIdUniform("uSource", inputTexId, 0)
            program.setFloatsUniform("uSize", floatArrayOf(width.toFloat(), height.toFloat()))
            DownscaledGaussian.draw(program)
            target
        } else {
            null
        }
        timelines[slot].add(presentationTimeUs, frame, onReplaced = ::recycle)
    }

    /**
     * The frame of each captured layer to draw over the frame composed at
     * [presentationTimeUs], `null` where the layer shows nothing; the frames
     * before them are recycled, since no later frame can choose them.
     */
    private fun framesAt(presentationTimeUs: Long): List<Frame?> {
        ensureContext()
        return timelines.map { it.take(presentationTimeUs, onDropped = ::recycle) }
    }

    /** A frame of [width] by [height] to copy into, recycled if one is free. */
    private fun obtain(width: Int, height: Int): Frame {
        if (width != frameWidth || height != frameHeight) {
            // Every frame of a composition is the canvas, so this only runs
            // once; frames of another size would not line up anyway.
            while (free.isNotEmpty()) delete(free.removeFirst())
            frameWidth = width
            frameHeight = height
        }
        free.removeFirstOrNull()?.let { return it }
        val texId = GlUtil.createTexture(width, height, /* useHighPrecisionColorComponents= */ false)
        return Frame(texId, GlUtil.createFboForTexture(texId))
    }

    private fun recycle(frame: Frame?) {
        if (frame != null) free.addLast(frame)
    }

    private fun delete(frame: Frame) {
        GlUtil.deleteFbo(frame.fboId)
        GlUtil.deleteTexture(frame.texId)
    }

    /**
     * Forgets everything captured in another GL context, whose objects this
     * one cannot see or delete.
     */
    private fun ensureContext() {
        val current = EGL14.eglGetCurrentContext()
        if (current == context) return
        if (context != null) {
            Log.w(RENDER_TAG, "Captured video layers: GL context changed; dropping captured frames")
        }
        context = current
        timelines.forEach { it.clear {} }
        free.clear()
        copyProgram = null
        frameWidth = 0
        frameHeight = 0
    }

    /** Deletes every captured frame; called once the composition is drawn. */
    private fun release() {
        if (EGL14.eglGetCurrentContext() != context) return
        timelines.forEach { timeline -> timeline.clear { it?.let(::delete) } }
        while (free.isNotEmpty()) delete(free.removeFirst())
        copyProgram?.delete()
        copyProgram = null
    }

    @UnstableApi
    private class CaptureEffect(
        private val layers: CapturedVideoLayers,
        private val slot: Int,
        private val copies: Boolean,
    ) : GlEffect {
        override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
            if (useHdr) {
                // RenderVideo pre-transcodes HDR sources of a composition with
                // a blended layer; this guards that gate.
                throw VideoFrameProcessingException("A blended video layer does not support HDR input")
            }
            return CaptureProgram(layers, slot, copies)
        }
    }

    @UnstableApi
    private class CaptureProgram(
        private val layers: CapturedVideoLayers,
        private val slot: Int,
        private val copies: Boolean,
    ) : BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ false, /* texturePoolCapacity= */ 1) {

        private var width = 0
        private var height = 0

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            width = inputWidth
            height = inputHeight
            return Size(inputWidth, inputHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            try {
                val outputFbo = VideoEffectGlow.currentFramebuffer()
                layers.capture(slot, presentationTimeUs, inputTexId, width, height, copies)
                // The compositor gets nothing to draw for this layer: the
                // composite effect draws it in its place.
                GlUtil.focusFramebufferUsingCurrentContext(outputFbo, width, height)
                GLES20.glClearColor(0f, 0f, 0f, 0f)
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e, presentationTimeUs)
            }
        }
    }

    @UnstableApi
    private class CompositeEffect(private val layers: CapturedVideoLayers) : GlEffect {
        override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
            if (useHdr) {
                throw VideoFrameProcessingException("A blended video layer does not support HDR input")
            }
            return CompositeProgram(layers)
        }
    }

    /**
     * Draws the captured frames onto the composed one, [MAX_LAYERS_PER_PASS] a
     * pass: every texture unit but the composed frame's holds one, and OpenGL
     * ES 2.0 guarantees eight. More layers take further passes, each over the
     * result of the one before.
     */
    @UnstableApi
    private class CompositeProgram(
        private val layers: CapturedVideoLayers,
    ) : BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ false, /* texturePoolCapacity= */ 1) {

        private val passes: List<Pair<IntRange, GlProgram>> =
            layers.modes.indices.chunked(MAX_LAYERS_PER_PASS).map { slots ->
                val range = slots.first()..slots.last()
                range to GlProgram(
                    VideoEffectGlow.VERTEX_SHADER,
                    compositeShader(slots.map { layers.modes[it] })
                )
            }
        private val intermediates = intArrayOf(NONE, NONE)
        private val intermediateFbos = intArrayOf(NONE, NONE)

        private var width = 0
        private var height = 0

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            width = inputWidth
            height = inputHeight
            return Size(inputWidth, inputHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            try {
                val outputFbo = VideoEffectGlow.currentFramebuffer()
                val frames = layers.framesAt(presentationTimeUs)
                var source = inputTexId
                for ((index, pass) in passes.withIndex()) {
                    val (slots, program) = pass
                    val last = index == passes.lastIndex
                    val target = index % 2
                    if (last) {
                        GlUtil.focusFramebufferUsingCurrentContext(outputFbo, width, height)
                    } else {
                        ensureIntermediate(target)
                        GlUtil.focusFramebufferUsingCurrentContext(
                            intermediateFbos[target], width, height
                        )
                    }
                    program.use()
                    program.setSamplerTexIdUniform("uPicture", source, 0)
                    program.setFloatsUniform(
                        "uPictureSize", floatArrayOf(width.toFloat(), height.toFloat())
                    )
                    for ((unit, slot) in slots.withIndex()) {
                        val frame = frames[slot]
                        // An empty slot still needs a bound sampler; the shader
                        // never reads it then.
                        program.setSamplerTexIdUniform("uLayer$unit", frame?.texId ?: source, unit + 1)
                        program.setFloatUniform("uHas$unit", if (frame != null) 1f else 0f)
                    }
                    DownscaledGaussian.draw(program)
                    if (!last) source = intermediates[target]
                }
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e, presentationTimeUs)
            }
        }

        private fun ensureIntermediate(index: Int) {
            if (intermediates[index] != NONE) return
            intermediates[index] =
                GlUtil.createTexture(width, height, /* useHighPrecisionColorComponents= */ false)
            intermediateFbos[index] = GlUtil.createFboForTexture(intermediates[index])
        }

        override fun release() {
            super.release()
            try {
                for (i in intermediates.indices) {
                    if (intermediateFbos[i] != NONE) GlUtil.deleteFbo(intermediateFbos[i])
                    if (intermediates[i] != NONE) GlUtil.deleteTexture(intermediates[i])
                    intermediateFbos[i] = NONE
                    intermediates[i] = NONE
                }
                layers.release()
            } catch (e: Exception) {
                throw VideoFrameProcessingException(e)
            } finally {
                passes.forEach { (_, program) ->
                    try {
                        program.delete()
                    } catch (e: Exception) {
                        Log.w(RENDER_TAG, "Captured video layers: program delete failed: ${e.message}")
                    }
                }
            }
        }
    }

    internal companion object {
        /** Captured layers one composite pass draws; see [CompositeProgram]. */
        const val MAX_LAYERS_PER_PASS = 7

        private const val NONE = -1

        // A texel-for-texel copy: the frame and the copy are the same size.
        private const val COPY_SHADER = VideoEffectGlow.PRECISION +
            "uniform sampler2D uSource;\n" +
            "uniform vec2 uSize;\n" +
            "void main() {\n" +
            "  gl_FragColor = texture2D(uSource, gl_FragCoord.xy / uSize);\n" +
            "}"

        /**
         * Draws captured layers, one per [modes] entry from the bottom up,
         * onto the picture. Every captured frame lies on the canvas as the
         * picture does, so both are read at the same texel.
         */
        fun compositeShader(modes: List<LayerBlendMode>): String {
            val uniforms = modes.indices.joinToString("") {
                "uniform sampler2D uLayer$it;\nuniform float uHas$it;\n"
            }
            val draws = modes.withIndex().joinToString("") { (i, mode) ->
                "  if (uHas$i > 0.5) {\n" +
                    "    vec4 layer$i = texture2D(uLayer$i, st);\n" +
                    "    if (layer$i.a > 0.0) " +
                    "color = ${LayerBlendShader.functionFor(mode)}(color, layer$i);\n" +
                    "  }\n"
            }
            return VideoEffectGlow.PRECISION +
                LayerBlendShader.FUNCTIONS +
                "uniform sampler2D uPicture;\n" +
                "uniform vec2 uPictureSize;\n" +
                uniforms +
                "void main() {\n" +
                "  vec2 st = gl_FragCoord.xy / uPictureSize;\n" +
                "  vec4 color = texture2D(uPicture, st);\n" +
                draws +
                "  gl_FragColor = color;\n" +
                "}"
        }
    }
}

/**
 * The frames captured of one layer, by presentation time, and which of them
 * goes with a composed frame.
 *
 * Media3's `DefaultVideoCompositor` draws, for each frame of the primary
 * sequence, the frame of every other sequence closest to it in time, the
 * earlier one of two equally close, and lets go of the ones before it. [take]
 * chooses the same. The compositor composes a frame only once every other
 * sequence has a frame after it or has ended, so the frames on both sides of
 * it are captured by then.
 */
internal class CapturedTimeline<T> {
    private val frames = TreeMap<Long, T>()

    /** How many frames are held. */
    val size: Int get() = frames.size

    /**
     * Holds [frame] at [timeUs]; one already held at that time is handed to
     * [onReplaced].
     */
    fun add(timeUs: Long, frame: T, onReplaced: (T) -> Unit) {
        if (frames.containsKey(timeUs)) onReplaced(frames.getValue(timeUs))
        frames[timeUs] = frame
    }

    /**
     * The frame closest to [timeUs], the earlier of two equally close, or
     * `null` when none is held. The frames before it are handed to
     * [onDropped] and let go: a later composed frame is closer to the chosen
     * one than to any of them.
     */
    fun take(timeUs: Long, onDropped: (T) -> Unit): T? {
        val before = frames.floorEntry(timeUs)
        val after = frames.ceilingEntry(timeUs)
        val chosen = when {
            before == null -> after
            after == null -> before
            timeUs - before.key <= after.key - timeUs -> before
            else -> after
        } ?: return null
        val older = frames.headMap(chosen.key, /* inclusive= */ false)
        older.values.forEach(onDropped)
        older.clear()
        return chosen.value
    }

    /** Hands every frame to [onDropped] and lets them go. */
    fun clear(onDropped: (T) -> Unit) {
        frames.values.forEach(onDropped)
        frames.clear()
    }
}
