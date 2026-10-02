// The bright pass of the video effect glow, for `VideoEffectPreview`.
//
// A pixel past the brightness threshold becomes `min(1, glow * k * rgb)`, as
// in Kotlin's `VideoEffectMath` step 8. The preview blurs this with Flutter's own
// Gaussian and screens it over the picture through a `BackdropFilter`.

#include <flutter/runtime_effect.glsl>

// Engine-set: the size of the bound texture. Must be the first uniform.
uniform vec2 uSize;

uniform float uGlow;
uniform float uThreshold;

// Engine-set: the filter input.
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
// Impeller's OpenGLES backend hands the texture over y-flipped.
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  vec4 c = texture(uTexture, uv);
  // Flutter's texture is premultiplied; a video frame is opaque.
  vec3 rgb = c.a > 0.0 ? c.rgb / c.a : vec3(0.0);
  float t = clamp(uThreshold, 0.0, 0.99);
  float l = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
  float k = clamp((l - t) / (1.0 - t), 0.0, 1.0);
  // Opaque, so the screen blend works on the halo's color alone.
  fragColor = vec4(min(vec3(1.0), uGlow * k * rgb), 1.0);
}
