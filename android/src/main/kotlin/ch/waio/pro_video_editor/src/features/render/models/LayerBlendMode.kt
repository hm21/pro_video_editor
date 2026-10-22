package ch.waio.pro_video_editor.src.features.render.models

/**
 * How a layer's pixels combine with the picture beneath it; Dart's
 * `LayerBlendMode`, matched by [wireName].
 *
 * Every mode is the separable blend of the W3C compositing spec, which is also
 * what Flutter's `BlendMode` of the same name paints: each color channel is
 * blended apart, and the layer's alpha fades between the backdrop and the
 * blended color. The colors are blended as they are stored, without
 * linearizing them, as Flutter and the Core Image renderer on iOS and macOS
 * (`workingColorSpace: NSNull()`) do. [ADD] is Flutter's `BlendMode.plus`:
 * the premultiplied colors are added and clamped. `LayerBlendShader` draws
 * them.
 */
enum class LayerBlendMode(val wireName: String) {
    NORMAL("normal"),
    MULTIPLY("multiply"),
    SCREEN("screen"),
    OVERLAY("overlay"),
    SOFT_LIGHT("softLight"),
    DARKEN("darken"),
    LIGHTEN("lighten"),
    ADD("add"),
    DIFFERENCE("difference");

    companion object {
        /** The mode named [raw], or [NORMAL] for anything else. */
        fun from(raw: Any?): LayerBlendMode = values().firstOrNull { it.wireName == raw } ?: NORMAL
    }
}
