package com.example.pro_video_editor_example

import ch.waio.pro_video_editor.effects.CustomVideoEffectFrame
import ch.waio.pro_video_editor.effects.CustomVideoEffectRenderer
import ch.waio.pro_video_editor.effects.CustomVideoEffectShader
import ch.waio.pro_video_editor.effects.CustomVideoEffects

/**
 * Custom video effects of the example app, which
 * `integration_test/custom_video_effect_test.dart` renders.
 */
object ExampleVideoEffects {
    /** Inverts the colors, mixed in by the `amount` param (0–1, default 1). */
    const val INVERT = "example.invert"

    /** Shows the frame from `delayMs` (default 500) earlier instead of the current one. */
    const val DELAY = "example.delay"

    fun register() {
        CustomVideoEffects.register(INVERT) { params -> InvertEffect(params) }
        CustomVideoEffects.register(DELAY) { params -> DelayEffect(params) }
    }
}

private class InvertEffect(params: Map<String, Any?>) : CustomVideoEffectRenderer() {
    private val amount = (params["amount"] as? Number)?.toFloat() ?: 1f

    private val shader = CustomVideoEffectShader(
        """
        precision mediump float;
        uniform sampler2D uFrame;
        uniform float uAmount;
        varying vec2 vTexCoord;
        void main() {
          vec4 color = texture2D(uFrame, vTexCoord);
          gl_FragColor = vec4(mix(color.rgb, 1.0 - color.rgb, uAmount), color.a);
        }
        """.trimIndent()
    )

    override fun render(frame: CustomVideoEffectFrame) {
        shader.use()
        shader.setTexture("uFrame", frame.textureId, 0)
        shader.setFloat("uAmount", amount)
        shader.draw()
    }

    override fun release() {
        shader.release()
    }
}

private class DelayEffect(params: Map<String, Any?>) : CustomVideoEffectRenderer() {
    override val historyOffsetsUs =
        longArrayOf(((params["delayMs"] as? Number)?.toLong() ?: 500L) * 1000L)

    private val shader = CustomVideoEffectShader(
        """
        precision mediump float;
        uniform sampler2D uFrame;
        varying vec2 vTexCoord;
        void main() {
          gl_FragColor = texture2D(uFrame, vTexCoord);
        }
        """.trimIndent()
    )

    override fun render(frame: CustomVideoEffectFrame) {
        shader.use()
        // Until the clip has played that long, there is no earlier frame.
        shader.setTexture("uFrame", frame.history.first()?.textureId ?: frame.textureId, 0)
        shader.draw()
    }

    override fun release() {
        shader.release()
    }
}
