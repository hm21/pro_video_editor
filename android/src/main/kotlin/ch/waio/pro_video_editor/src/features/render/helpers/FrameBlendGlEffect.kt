package ch.waio.pro_video_editor.src.features.render.helpers

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.GlObjectsProvider
import androidx.media3.common.GlTextureInfo
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import ch.waio.pro_video_editor.effects.CustomVideoEffectShader
import com.google.common.util.concurrent.MoreExecutors
import java.util.concurrent.Executor

/**
 * Fills the frames a slowed-down clip holds with cross-fades of its
 * neighbouring source frames.
 *
 * Goes right after the clip's speed change, so the frames it sees are already
 * on the output timeline. It puts out a frame every [frameUs] from the clip's
 * first frame, each mixing the source frames around it as
 * [FrameBlendSchedule] places it; one input frame can give several output
 * frames, or none on a sped-up stretch.
 *
 * Every input stream is a clip of its own: blending starts over at every cut,
 * so a clip never mixes in the one before it.
 */
@UnstableApi
class FrameBlendGlEffect(private val frameUs: Long) : GlEffect {

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        FrameBlendShaderProgram(frameUs, useHdr)

    override fun isNoOp(inputWidth: Int, inputHeight: Int): Boolean = false
}

/**
 * The [GlShaderProgram] behind [FrameBlendGlEffect].
 *
 * Holds one input frame at a time: an output frame needs the input frame
 * after it, so frames go out one input late. The last frame of a stream goes
 * out at its own time when the stream ends.
 */
@UnstableApi
private class FrameBlendShaderProgram(
    private val frameUs: Long,
    private val useHighPrecisionColorComponents: Boolean,
) : GlShaderProgram {

    private var inputListener: GlShaderProgram.InputListener =
        object : GlShaderProgram.InputListener {}
    private var outputListener: GlShaderProgram.OutputListener =
        object : GlShaderProgram.OutputListener {}
    private var errorListener: GlShaderProgram.ErrorListener =
        GlShaderProgram.ErrorListener { }
    private var errorExecutor: Executor = MoreExecutors.directExecutor()

    private var shader: CustomVideoEffectShader? = null
    private var width = 0
    private var height = 0

    /** Copy of the last input frame that left [held], and its time. */
    private var previous: GlTextureInfo? = null
    private var previousUs = C.TIME_UNSET

    /** The input frame being blended towards; owned until its frames are out. */
    private var held: GlTextureInfo? = null
    private var heldUs = C.TIME_UNSET

    /** The clip's first frame time, where the output grid starts. */
    private var originUs = C.TIME_UNSET

    /** Output frames still to draw, mixing [previous] towards [held]. */
    private val pending = ArrayDeque<BlendedFrame>()
    private var endOfStreamRequested = false

    private val freeOutputs = ArrayDeque<GlTextureInfo>()
    private val usedOutputs = mutableListOf<GlTextureInfo>()

    /** Output textures of an earlier size, deleted once they come back. */
    private val retiredOutputs = mutableListOf<GlTextureInfo>()

    override fun setInputListener(inputListener: GlShaderProgram.InputListener) {
        this.inputListener = inputListener
        inputListener.onReadyToAcceptInputFrame()
    }

    override fun setOutputListener(outputListener: GlShaderProgram.OutputListener) {
        this.outputListener = outputListener
    }

    override fun setErrorListener(executor: Executor, errorListener: GlShaderProgram.ErrorListener) {
        this.errorExecutor = executor
        this.errorListener = errorListener
    }

    override fun queueInputFrame(
        glObjectsProvider: GlObjectsProvider,
        inputTexture: GlTextureInfo,
        presentationTimeUs: Long,
    ) {
        try {
            ensureConfigured(glObjectsProvider, inputTexture.width, inputTexture.height)
            held = inputTexture
            heldUs = presentationTimeUs
            if (originUs == C.TIME_UNSET) originUs = presentationTimeUs
            if (previousUs != C.TIME_UNSET) {
                pending += FrameBlendSchedule.between(previousUs, presentationTimeUs, originUs, frameUs)
            }
            drain()
        } catch (e: Exception) {
            reportError(e, presentationTimeUs)
        }
    }

    override fun releaseOutputFrame(outputTexture: GlTextureInfo) {
        if (!usedOutputs.remove(outputTexture)) return
        try {
            if (retiredOutputs.remove(outputTexture)) {
                outputTexture.release()
            } else {
                freeOutputs += outputTexture
            }
            drain()
        } catch (e: Exception) {
            reportError(e, C.TIME_UNSET)
        }
    }

    override fun signalEndOfCurrentInputStream() {
        endOfStreamRequested = true
        try {
            drain()
        } catch (e: Exception) {
            reportError(e, C.TIME_UNSET)
        }
    }

    override fun flush() {
        pending.clear()
        held = null
        heldUs = C.TIME_UNSET
        previousUs = C.TIME_UNSET
        originUs = C.TIME_UNSET
        endOfStreamRequested = false
        freeOutputs += usedOutputs.filterNot { it in retiredOutputs }
        usedOutputs.clear()
        inputListener.onFlush()
        inputListener.onReadyToAcceptInputFrame()
    }

    override fun release() {
        try {
            for (texture in (freeOutputs + usedOutputs + retiredOutputs).toSet()) texture.release()
            freeOutputs.clear()
            usedOutputs.clear()
            retiredOutputs.clear()
            previous?.release()
            previous = null
            shader?.release()
            shader = null
        } catch (e: GlUtil.GlException) {
            throw VideoFrameProcessingException(e)
        }
    }

    /**
     * Puts out what can go out with the output textures free now, then lets
     * the held frame go once nothing needs it any more.
     */
    private fun drain() {
        val held = held
        while (pending.isNotEmpty() && freeOutputs.isNotEmpty()) {
            val frame = pending.removeFirst()
            val output = freeOutputs.removeFirst()
            usedOutputs += output
            draw(output, previous!!.texId, held!!.texId, frame.weight)
            outputListener.onOutputFrameAvailable(output, frame.presentationTimeUs)
        }
        if (pending.isNotEmpty()) return

        if (held != null) {
            // The held frame becomes the one later frames blend from.
            draw(previous!!, held.texId, held.texId, 1f)
            previousUs = heldUs
            this.held = null
            heldUs = C.TIME_UNSET
            inputListener.onInputFrameProcessed(held)
            inputListener.onReadyToAcceptInputFrame()
        }

        if (!endOfStreamRequested) return
        if (previousUs != C.TIME_UNSET) {
            // The last frame has no frame after it to blend towards, so it
            // goes out on its own, at its own time.
            if (freeOutputs.isEmpty()) return
            val output = freeOutputs.removeFirst()
            usedOutputs += output
            val texture = previous!!.texId
            draw(output, texture, texture, 0f)
            outputListener.onOutputFrameAvailable(output, previousUs)
            previousUs = C.TIME_UNSET
        }
        originUs = C.TIME_UNSET
        endOfStreamRequested = false
        outputListener.onCurrentOutputStreamEnded()
    }

    private fun draw(target: GlTextureInfo, fromTexture: Int, toTexture: Int, weight: Float) {
        val shader = shader!!
        GlUtil.focusFramebufferUsingCurrentContext(target.fboId, target.width, target.height)
        shader.use()
        shader.setTexture("uFrom", fromTexture, 0)
        shader.setTexture("uTo", toTexture, 1)
        shader.setFloat("uWeight", weight)
        shader.draw()
    }

    /**
     * Sizes the copy of the previous frame and the output textures to the
     * input. Textures still out with the next stage are deleted once they
     * come back rather than under it.
     */
    private fun ensureConfigured(provider: GlObjectsProvider, inputWidth: Int, inputHeight: Int) {
        if (shader == null) shader = CustomVideoEffectShader(BLEND_SHADER)
        if (inputWidth == width && inputHeight == height && previous != null) return

        for (texture in freeOutputs) texture.release()
        freeOutputs.clear()
        retiredOutputs += usedOutputs
        previous?.release()

        width = inputWidth
        height = inputHeight
        previous = newTexture(provider)
        repeat(OUTPUT_CAPACITY) { freeOutputs += newTexture(provider) }
        // A frame of the old size cannot be blended with one of the new.
        previousUs = C.TIME_UNSET
    }

    private fun newTexture(provider: GlObjectsProvider): GlTextureInfo {
        val texture = GlUtil.createTexture(width, height, useHighPrecisionColorComponents)
        return provider.createBuffersForTexture(texture, width, height)
    }

    private fun reportError(e: Exception, presentationTimeUs: Long) {
        val error = VideoFrameProcessingException.from(e, presentationTimeUs)
        errorExecutor.execute { errorListener.onError(error) }
    }

    private companion object {
        /** Lets the next stage hold one frame while the next one is drawn. */
        const val OUTPUT_CAPACITY = 2

        // highp keeps the texture coordinate exact enough to land on texel
        // centers of a large frame, so a weight of 0 or 1 copies the pixels
        // as they are.
        const val BLEND_SHADER =
            "#ifdef GL_FRAGMENT_PRECISION_HIGH\n" +
                "precision highp float;\n" +
                "#else\n" +
                "precision mediump float;\n" +
                "#endif\n" +
                "uniform sampler2D uFrom;\n" +
                "uniform sampler2D uTo;\n" +
                "uniform float uWeight;\n" +
                "varying vec2 vTexCoord;\n" +
                "void main() {\n" +
                "  gl_FragColor = mix(texture2D(uFrom, vTexCoord), texture2D(uTo, vTexCoord), uWeight);\n" +
                "}"
    }
}
