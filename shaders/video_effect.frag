// Live preview of a VideoEffectFrame, for `VideoEffectPreview`.
//
// This is the third implementation of the effect pipeline. The other two are
// the Android render shader (`VideoEffectShaderProgram.kt`) and the Apple Core
// Image stage (`ApplyVideoEffect.swift`), and all three follow the same spec:
// pixelate, shift the bands, split the channels, darken the scanlines, add the
// noise, tone the colors, darken the corners. Keep them in lockstep.
//
// Every size arrives as a fraction of the frame and is rounded to whole pixels
// here, so each step copies whole texels and nothing is interpolated. Integer
// arithmetic is done in floats, which is exact below 2^24; `idiv` and `imod`
// add half a unit before dividing so an approximate GPU division cannot put a
// quotient on the wrong side of an integer.

#include <flutter/runtime_effect.glsl>

// Engine-set: the size of the bound texture. Must be the first uniform.
uniform vec2 uSize;

uniform float uPixelSize;
uniform float uRgbShift;
uniform float uScanlines;
uniform float uScanlinePeriod;
uniform float uNoise;
uniform float uNoiseCellSize;
uniform vec2 uNoiseOffset;
uniform float uBandCount;
// (top, bottom, shift) of each band; the first band that covers a row wins.
uniform vec3 uBand0;
uniform vec3 uBand1;
uniform vec3 uBand2;
uniform vec3 uBand3;
uniform float uSepia;
uniform float uBrightness;
uniform float uInvert;
uniform float uFlash;
uniform float uVignette;
uniform float uVignetteRadius;

// Engine-set: the filter input.
uniform sampler2D uTexture;

out vec4 fragColor;

float toPixels(float fraction, float size) {
  return floor(fraction * size + 0.5);
}

float idiv(float a, float b) {
  return floor((a + 0.5) / b);
}

float imod(float a, float b) {
  return a - b * idiv(a, b);
}

// A value in [0, 1) for a cell of the 128x128 noise tile.
float noiseAt(float u, float v) {
  float a = imod(u * 37.0 + v * 101.0 + 13.0, 251.0);
  a = imod(a * a + u * 7.0 + 17.0, 251.0);
  a = imod(a * a + v * 3.0 + 29.0, 251.0);
  return a / 251.0;
}

// The texel at whole-pixel coordinates, counted from the top-left corner.
vec4 fetch(vec2 texel) {
  texel = clamp(texel, vec2(0.0), uSize - 1.0);
  vec2 uv = (texel + 0.5) / uSize;
// Impeller's OpenGLES backend hands the texture over y-flipped.
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uTexture, uv);
}

vec4 pixelated(float x, float y) {
  x = clamp(x, 0.0, uSize.x - 1.0);
  float block = toPixels(uPixelSize, uSize.x);
  if (block >= 2.0) {
    float center = floor(block / 2.0);
    x = idiv(x, block) * block + center;
    y = idiv(y, block) * block + center;
  }
  return fetch(vec2(x, y));
}

vec4 banded(float x, float y, float shift) {
  x = clamp(x, 0.0, uSize.x - 1.0);
  return pixelated(clamp(x - shift, 0.0, uSize.x - 1.0), y);
}

bool covers(vec3 band, float y) {
  return y >= toPixels(band.x, uSize.y) && y < toPixels(band.y, uSize.y);
}

void main() {
  vec2 p = floor(FlutterFragCoord().xy);

  float shift = 0.0;
  if (uBandCount > 3.5 && covers(uBand3, p.y)) shift = toPixels(uBand3.z, uSize.x);
  if (uBandCount > 2.5 && covers(uBand2, p.y)) shift = toPixels(uBand2.z, uSize.x);
  if (uBandCount > 1.5 && covers(uBand1, p.y)) shift = toPixels(uBand1.z, uSize.x);
  if (uBandCount > 0.5 && covers(uBand0, p.y)) shift = toPixels(uBand0.z, uSize.x);

  float split = toPixels(uRgbShift, uSize.x);
  vec4 center = banded(p.x, p.y, shift);
  vec3 rgb = vec3(
      banded(p.x + split, p.y, shift).r,
      center.g,
      banded(p.x - split, p.y, shift).b);

  if (uScanlines > 0.0) {
    float period = max(2.0, toPixels(uScanlinePeriod, uSize.y));
    if (imod(p.y, period) * 2.0 >= period) rgb *= 1.0 - uScanlines;
  }

  // Flutter's texture is premultiplied, so the grain is scaled by alpha and
  // the result kept within it; a video frame is opaque and unaffected.
  float a = center.a;
  if (uNoise > 0.0) {
    float cell = max(1.0, toPixels(uNoiseCellSize, uSize.y));
    float u = imod(idiv(p.x, cell) + uNoiseOffset.x, 128.0);
    float v = imod(idiv(p.y, cell) + uNoiseOffset.y, 128.0);
    rgb += (noiseAt(u, v) - 0.5) * uNoise * a;
  }

  rgb = clamp(rgb, 0.0, a);

  // The tones are affine, so on premultiplied colors their constant terms are
  // scaled by alpha.
  if (uSepia > 0.0) {
    vec3 sepia = vec3(
        dot(rgb, vec3(0.393, 0.769, 0.189)),
        dot(rgb, vec3(0.349, 0.686, 0.168)),
        dot(rgb, vec3(0.272, 0.534, 0.131)));
    rgb = mix(rgb, sepia, uSepia);
  }
  rgb *= 1.0 + uBrightness;
  rgb += uInvert * (a - 2.0 * rgb);
  rgb += uFlash * (a - rgb);
  rgb = clamp(rgb, 0.0, a);

  if (uVignette > 0.0) {
    float radius = clamp(uVignetteRadius, 0.0, 0.99);
    vec2 d = (2.0 * p + 1.0) / uSize - 1.0;
    float t = clamp((sqrt(dot(d, d) / 2.0) - radius) / (1.0 - radius), 0.0, 1.0);
    rgb *= 1.0 - uVignette * t * t;
  }

  fragColor = vec4(clamp(rgb, 0.0, a), a);
}
