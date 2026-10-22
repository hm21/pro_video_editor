package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.LayerBlendMode

/** GLSL that draws a layer onto a backdrop in a [LayerBlendMode]. */
internal object LayerBlendShader {

    /** The function of [FUNCTIONS] that draws a layer pixel in [mode]. */
    fun functionFor(mode: LayerBlendMode): String = when (mode) {
        LayerBlendMode.NORMAL -> "blendNormal"
        LayerBlendMode.MULTIPLY -> "blendMultiply"
        LayerBlendMode.SCREEN -> "blendScreen"
        LayerBlendMode.OVERLAY -> "blendOverlay"
        LayerBlendMode.SOFT_LIGHT -> "blendSoftLight"
        LayerBlendMode.DARKEN -> "blendDarken"
        LayerBlendMode.LIGHTEN -> "blendLighten"
        LayerBlendMode.ADD -> "blendAdd"
        LayerBlendMode.DIFFERENCE -> "blendDifference"
    }

    /**
     * One function per mode, `vec4 blendX(vec4 backdrop, vec4 layer)`,
     * that draws a layer pixel onto a backdrop pixel. Both carry straight
     * (not premultiplied) alpha, as Media3's textures do, and so does the
     * result.
     *
     * `composite` is the W3C source-over with the blended color mixed in
     * where both are there: `layer.a * (1 - backdrop.a) * layer.rgb +
     * layer.a * backdrop.a * B + (1 - layer.a) * backdrop.a * backdrop.rgb`
     * over the composited alpha. Over an opaque backdrop that is
     * `mix(backdrop.rgb, B, layer.a)`. The conditional branches use `step`,
     * and both sides of each meet at the threshold, so it does not matter
     * which side the threshold falls on.
     */
    const val FUNCTIONS =
        "vec4 composite(vec4 b, vec4 s, vec3 blended) {\n" +
        "  float a = s.a + b.a * (1.0 - s.a);\n" +
        "  if (a <= 0.0) return vec4(0.0);\n" +
        "  vec3 pre = s.a * (1.0 - b.a) * s.rgb + s.a * b.a * blended +\n" +
        "      (1.0 - s.a) * b.a * b.rgb;\n" +
        "  return vec4(pre / a, a);\n" +
        "}\n" +
        "vec4 blendNormal(vec4 b, vec4 s) { return composite(b, s, s.rgb); }\n" +
        "vec4 blendMultiply(vec4 b, vec4 s) { return composite(b, s, b.rgb * s.rgb); }\n" +
        "vec4 blendScreen(vec4 b, vec4 s) {\n" +
        "  return composite(b, s, b.rgb + s.rgb - b.rgb * s.rgb);\n" +
        "}\n" +
        "vec4 blendOverlay(vec4 b, vec4 s) {\n" +
        "  vec3 dark = 2.0 * b.rgb * s.rgb;\n" +
        "  vec3 light = 1.0 - 2.0 * (1.0 - b.rgb) * (1.0 - s.rgb);\n" +
        "  return composite(b, s, mix(dark, light, step(0.5, b.rgb)));\n" +
        "}\n" +
        "vec4 blendSoftLight(vec4 b, vec4 s) {\n" +
        "  vec3 d = mix(((16.0 * b.rgb - 12.0) * b.rgb + 4.0) * b.rgb, sqrt(b.rgb),\n" +
        "      step(0.25, b.rgb));\n" +
        "  vec3 dark = b.rgb - (1.0 - 2.0 * s.rgb) * b.rgb * (1.0 - b.rgb);\n" +
        "  vec3 light = b.rgb + (2.0 * s.rgb - 1.0) * (d - b.rgb);\n" +
        "  return composite(b, s, mix(dark, light, step(0.5, s.rgb)));\n" +
        "}\n" +
        "vec4 blendDarken(vec4 b, vec4 s) { return composite(b, s, min(b.rgb, s.rgb)); }\n" +
        "vec4 blendLighten(vec4 b, vec4 s) { return composite(b, s, max(b.rgb, s.rgb)); }\n" +
        "vec4 blendDifference(vec4 b, vec4 s) {\n" +
        "  return composite(b, s, abs(b.rgb - s.rgb));\n" +
        "}\n" +
        "vec4 blendAdd(vec4 b, vec4 s) {\n" +
        "  float a = min(s.a + b.a, 1.0);\n" +
        "  if (a <= 0.0) return vec4(0.0);\n" +
        "  return vec4(min(s.a * s.rgb + b.a * b.rgb, 1.0) / a, a);\n" +
        "}\n"
}
