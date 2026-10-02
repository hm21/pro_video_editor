// Live preview of a VideoEffectFrame, for `VideoEffectPreview`.
//
// This is the third implementation of the effect pipeline. The other two are
// the Android render shader (`VideoEffectGlEffect.kt`) and the Apple Core
// Image stage (`ApplyVideoEffect.swift`), and all three follow the same spec
// (Kotlin's `VideoEffectMath`): the geometry stages (wave; zoom, move and
// mirror; tiles), then pixelate, shift the bands, split the channels, darken
// the scanlines, add the noise, tone the colors, darken the corners. Keep them
// in lockstep.
//
// Every size arrives as a fraction of the frame and is rounded to whole pixels
// here, so after the geometry each step copies whole texels and nothing is
// interpolated. The geometry stages filter bilinearly, each over the picture
// the stage before it produced. Integer arithmetic is done in floats, which is
// exact below 2^24; `idiv` and `imod` add half a unit before dividing so an
// approximate GPU division cannot put a quotient on the wrong side of an
// integer.

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
uniform float uZoom;
uniform vec2 uOffset;
uniform vec2 uMirror;
uniform float uTiles;
// (amplitude, period, phase) of the wave.
uniform vec3 uWave;

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

// The source texel at whole-pixel coordinates, counted from the top-left
// corner.
vec4 source(vec2 texel) {
  texel = clamp(texel, vec2(0.0), uSize - 1.0);
  vec2 uv = (texel + 0.5) / uSize;
// Impeller's OpenGLES backend hands the texture over y-flipped.
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uTexture, uv);
}

// Bilinear filtering of the source at position `p` in pixels, where pixel i
// has its center at i + 0.5. GLSL takes no function arguments, so each
// geometry stage has its own copy of this. The loops keep every stage a single
// copy in the compiled shader; unrolled, the nested stages multiply.
vec4 sourceAt(vec2 p) {
  vec2 t = p - 0.5;
  vec2 i = floor(t);
  vec2 f = t - i;
  vec4 sum = vec4(0.0);
  for (int n = 0; n < 4; n++) {
    vec2 o = vec2(float(n - 2 * (n / 2)), float(n / 2));
    vec2 w = mix(1.0 - f, f, o);
    if (w.x * w.y > 0.0) sum += w.x * w.y * source(i + o);
  }
  return sum;
}

// How far the row whose center is `y` pixels down moves: a sine drawn with
// sixteen straight segments per wave.
float waveShift(float y) {
  float period = max(uWave.y, 0.1) * uSize.y;
  float t = (y / period + uWave.z) * 16.0;
  float k = floor(t);
  float from = sin(6.283185307179586 * k / 16.0);
  float to = sin(6.283185307179586 * (k + 1.0) / 16.0);
  return uWave.x * uSize.x * (from + (to - from) * (t - k));
}

// Geometry stage 1: rows bent sideways.
vec4 waved(vec2 texel) {
  if (uWave.x == 0.0 || uWave.y <= 0.0) return source(texel);
  texel = clamp(texel, vec2(0.0), uSize - 1.0);
  return sourceAt(vec2(texel.x + 0.5 - waveShift(texel.y + 0.5), texel.y + 0.5));
}

// `sourceAt` over the bent picture.
vec4 wavedAt(vec2 p) {
  vec2 t = p - 0.5;
  vec2 i = floor(t);
  vec2 f = t - i;
  vec4 sum = vec4(0.0);
  for (int n = 0; n < 4; n++) {
    vec2 o = vec2(float(n - 2 * (n / 2)), float(n / 2));
    vec2 w = mix(1.0 - f, f, o);
    if (w.x * w.y > 0.0) sum += w.x * w.y * waved(i + o);
  }
  return sum;
}

// Geometry stage 2: zoom, move and mirror.
vec4 transformed(vec2 texel) {
  if (uZoom <= 0.0 && uOffset == vec2(0.0) && uMirror.x <= 0.0 &&
      uMirror.y <= 0.0) {
    return waved(texel);
  }
  texel = clamp(texel, vec2(0.0), uSize - 1.0);
  vec2 mirrored = min(
      vec2(toPixels(uMirror.x, uSize.x), toPixels(uMirror.y, uSize.y)),
      floor(uSize / 2.0));
  vec2 axis = uSize - mirrored;
  if (uMirror.x > 0.0 && texel.x >= axis.x) texel.x = 2.0 * axis.x - 1.0 - texel.x;
  if (uMirror.y > 0.0 && texel.y >= axis.y) texel.y = 2.0 * axis.y - 1.0 - texel.y;
  vec2 c = uSize / 2.0;
  return wavedAt((texel + 0.5 - c - uOffset * uSize) / (1.0 + max(uZoom, 0.0)) + c);
}

// `sourceAt` over the zoomed, moved and mirrored picture.
vec4 transformedAt(vec2 p) {
  vec2 t = p - 0.5;
  vec2 i = floor(t);
  vec2 f = t - i;
  vec4 sum = vec4(0.0);
  for (int n = 0; n < 4; n++) {
    vec2 o = vec2(float(n - 2 * (n / 2)), float(n / 2));
    vec2 w = mix(1.0 - f, f, o);
    if (w.x * w.y > 0.0) sum += w.x * w.y * transformed(i + o);
  }
  return sum;
}

// Geometry stage 3, the picture every later step reads: the picture at half
// its size, four times. The doubled pixel center is a whole number, so `imod`
// keeps the middle column of an odd width in the copy the spec puts it in.
vec4 picture(vec2 texel) {
  if (uTiles < 1.5) return transformed(texel);
  texel = clamp(texel, vec2(0.0), uSize - 1.0);
  vec2 doubled = texel * 2.0 + 1.0;
  return transformedAt(vec2(imod(doubled.x, uSize.x), imod(doubled.y, uSize.y)));
}

vec4 pixelated(float x, float y) {
  x = clamp(x, 0.0, uSize.x - 1.0);
  float block = toPixels(uPixelSize, uSize.x);
  if (block >= 2.0) {
    float center = floor(block / 2.0);
    x = idiv(x, block) * block + center;
    y = idiv(y, block) * block + center;
  }
  return picture(vec2(x, y));
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

  // Green and alpha in place, red from the right and blue from the left, in a
  // loop so the geometry stages behind `banded` are compiled once.
  float split = toPixels(uRgbShift, uSize.x);
  vec4 center = vec4(0.0);
  vec3 rgb = vec3(0.0);
  for (int k = 0; k < 3; k++) {
    if (k > 0 && split == 0.0) break;
    vec4 c = banded(p.x + (k == 1 ? split : (k == 2 ? -split : 0.0)), p.y, shift);
    if (k == 0) {
      center = c;
      rgb = c.rgb;
    } else if (k == 1) {
      rgb.r = c.r;
    } else {
      rgb.b = c.b;
    }
  }

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
