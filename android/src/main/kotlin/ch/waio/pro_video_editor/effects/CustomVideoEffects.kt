package ch.waio.pro_video_editor.effects

import android.opengl.GLES20
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import java.util.concurrent.ConcurrentHashMap

/**
 * The video effects an app implements itself, by id.
 *
 * A Dart `CustomVideoEffect` names one of these ids; every render that carries
 * it asks the registered [CustomVideoEffectFactory] for a renderer and runs it
 * on each frame inside the effect's time range. Register before the first
 * render, for example in `MainActivity.configureFlutterEngine`:
 *
 * ```kotlin
 * CustomVideoEffects.register("my.echo") { params -> EchoRenderer(params) }
 * ```
 *
 * A render that names an id nothing is registered under fails.
 */
object CustomVideoEffects {
    private val factories = ConcurrentHashMap<String, CustomVideoEffectFactory>()

    /** Registers [factory] under [id], replacing whatever was registered there. */
    @JvmStatic
    fun register(id: String, factory: CustomVideoEffectFactory) {
        require(id.isNotEmpty()) { "A custom video effect id must not be empty" }
        factories[id] = factory
    }

    /** Removes what is registered under [id]; renders that already started keep it. */
    @JvmStatic
    fun unregister(id: String) {
        factories.remove(id)
    }

    /** Whether something is registered under [id]. */
    @JvmStatic
    fun isRegistered(id: String): Boolean = factories.containsKey(id)

    internal fun factory(id: String): CustomVideoEffectFactory? = factories[id]
}

/** Creates the renderer of a custom video effect for one render. */
fun interface CustomVideoEffectFactory {
    /**
     * Returns a new renderer for one render of the effect.
     *
     * Called on the render's GL thread with its context current, so the
     * renderer may compile its shaders right away. [params] are the Dart
     * `CustomVideoEffect.params`, as the platform channel decoded them.
     */
    fun create(params: Map<String, Any?>): CustomVideoEffectRenderer
}

/**
 * Draws one custom video effect, frame by frame, on the GPU.
 *
 * Every method runs on the render's GL thread with its context current.
 */
abstract class CustomVideoEffectRenderer {
    /**
     * The earlier frames [render] receives, as how far each lies before the
     * current frame, in microseconds of the rendered video. Read once, when
     * the render starts.
     *
     * Earlier frames come from the same clip only: on the first frames of a
     * clip, the ones further back than the clip has played are `null`.
     */
    open val historyOffsetsUs: LongArray = LongArray(0)

    /**
     * The size earlier frames are kept at, relative to the video, from 0.05
     * to 1. Lower values save memory: a 1080x1920 frame takes about 8.3 MB
     * at 1 and a quarter of that at 0.5.
     */
    open val historyScale: Float = 1f

    /** Called with the frame size before the first frame and whenever it changes. */
    open fun configure(width: Int, height: Int) {}

    /**
     * Draws [frame] with the effect into the bound framebuffer, which is the
     * size of the frame and already focused.
     *
     * Leave the framebuffer binding as it is. [CustomVideoEffectShader]
     * draws a quad over it.
     */
    abstract fun render(frame: CustomVideoEffectFrame)

    /** Releases the renderer's GL objects, once the render is done with it. */
    open fun release() {}
}

/** The frame a [CustomVideoEffectRenderer] draws. */
class CustomVideoEffectFrame internal constructor(
    /** The current frame, a `GL_TEXTURE_2D` with its origin at the bottom left. */
    val textureId: Int,
    /** Width of the frame in pixels. */
    val width: Int,
    /** Height of the frame in pixels. */
    val height: Int,
    /** Time of this frame on the rendered video, in microseconds. */
    val timeUs: Long,
    /** Time since the effect's start time, in microseconds. */
    val effectTimeUs: Long,
    /**
     * One entry per [CustomVideoEffectRenderer.historyOffsetsUs], in the same
     * order: the newest earlier frame at least that far back, or `null` when
     * the clip has not played that long yet.
     */
    val history: List<CustomVideoEffectHistoryFrame?>,
)

/** An earlier frame of the clip, kept for a [CustomVideoEffectRenderer]. */
class CustomVideoEffectHistoryFrame internal constructor(
    /** The frame, a `GL_TEXTURE_2D` with its origin at the bottom left. */
    val textureId: Int,
    /** Width of the stored frame, scaled by [CustomVideoEffectRenderer.historyScale]. */
    val width: Int,
    /** Height of the stored frame, scaled by [CustomVideoEffectRenderer.historyScale]. */
    val height: Int,
    /** Time of this frame on the rendered video, in microseconds. */
    val timeUs: Long,
)

/**
 * A fragment shader drawn as a quad over the whole bound framebuffer, for
 * writing a [CustomVideoEffectRenderer] without OpenGL boilerplate.
 *
 * The vertex shader hands the fragment shader `varying vec2 vTexCoord`, from
 * (0, 0) at the bottom left to (1, 1) at the top right, which samples a
 * frame texture as it is. Declare it in the fragment shader:
 *
 * ```glsl
 * precision highp float;
 * uniform sampler2D uFrame;
 * varying vec2 vTexCoord;
 * void main() { gl_FragColor = texture2D(uFrame, vTexCoord); }
 * ```
 *
 * Create it on the GL thread, in [CustomVideoEffectFactory.create] or
 * later, and [release] it in [CustomVideoEffectRenderer.release].
 */
class CustomVideoEffectShader(fragmentShaderSource: String) {
    private val program = GlProgram(VERTEX_SHADER, fragmentShaderSource)

    /** Makes this the active program; call before setting values and [draw]. */
    fun use() {
        program.use()
    }

    /** Binds the `GL_TEXTURE_2D` [textureId] to the sampler [name] on texture unit [unit]. */
    fun setTexture(name: String, textureId: Int, unit: Int) {
        program.setSamplerTexIdUniform(name, textureId, unit)
    }

    /** Sets the `float` uniform [name]. */
    fun setFloat(name: String, value: Float) {
        program.setFloatUniform(name, value)
    }

    /** Sets the `vec2`, `vec3`, `vec4` or matrix uniform [name]. */
    fun setFloats(name: String, values: FloatArray) {
        program.setFloatsUniform(name, values)
    }

    /** Sets the `int` uniform [name]. */
    fun setInt(name: String, value: Int) {
        program.setIntUniform(name, value)
    }

    /** Draws the quad with the values set since [use]. */
    fun draw() {
        val vertices = GlUtil.getNormalizedCoordinateBounds()
        program.setBufferAttribute("aFramePosition", vertices, if (vertices.size == 8) 2 else 4)
        program.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GlUtil.checkGlError()
        // A sampler on a later unit leaves that unit active; hand the first back.
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    }

    /** Deletes the program. */
    fun release() {
        program.delete()
    }

    private companion object {
        const val VERTEX_SHADER =
            "attribute vec4 aFramePosition;\n" +
            "varying vec2 vTexCoord;\n" +
            "void main() {\n" +
            "  gl_Position = aFramePosition;\n" +
            "  vTexCoord = aFramePosition.xy * 0.5 + 0.5;\n" +
            "}"
    }
}
