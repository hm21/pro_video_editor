import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// A horizontal slice of the frame that is shifted sideways.
///
/// Used by [VideoEffectFrame.bands]. All values are fractions of the frame, so
/// the same band covers the same part of the picture at any resolution.
@immutable
class VideoEffectBand {
  /// Creates a band covering the rows from [top] to [bottom], shifted by
  /// [shift].
  const VideoEffectBand({
    required this.top,
    required this.bottom,
    required this.shift,
  });

  /// The first row of the band, as a fraction of the frame height from the
  /// top edge.
  final double top;

  /// The row after the band's last one, as a fraction of the frame height from
  /// the top edge.
  final double bottom;

  /// How far the band's content moves, as a fraction of the frame width.
  ///
  /// Positive values move it to the right. Pixels that would come from beyond
  /// the frame edge repeat the edge column.
  final double shift;

  @override
  bool operator ==(Object other) =>
      other is VideoEffectBand &&
      other.top == top &&
      other.bottom == bottom &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(top, bottom, shift);

  @override
  String toString() =>
      'VideoEffectBand(top: $top, bottom: $bottom, shift: $shift)';
}

/// The pixel operations a [VideoEffect] applies to one frame.
///
/// Every renderer applies them in the same order. First the geometry, in three
/// stages: zoom, move and mirror the picture ([zoom], [offsetX], [offsetY],
/// [mirrorX], [mirrorY]), repeat it in a grid ([tiles]), then bend its rows
/// along a wave ([waveAmplitude]). Then pixelate, shift the [bands], split the
/// color channels, darken the scanlines, add the noise, tone the colors
/// ([sepia], [brightness], [invert], [flash]), and darken the edges
/// ([vignette]). The colors are clamped to 0..1 after the noise and again
/// after the tones, not between the tones.
///
/// Sizes are fractions of the frame, so a preview and an export at another
/// resolution show the same picture; each renderer rounds them to whole pixels
/// with `floor(fraction * size + 0.5)`. Only the geometry moves the picture by
/// fractions of a pixel: each of its stages reads the picture the stage before
/// produced with bilinear filtering, repeating the edge pixels beyond the
/// frame.
///
/// A [VideoEffect] produces one of these for every point in time; the native
/// renderers only ever see frames, so the look of an effect is defined once,
/// in Dart.
@immutable
class VideoEffectFrame {
  /// Creates a frame. Every operation defaults to off.
  const VideoEffectFrame({
    this.pixelSize = 0,
    this.rgbShift = 0,
    this.scanlines = 0,
    this.scanlinePeriod = 0,
    this.noise = 0,
    this.noiseCellSize = 0,
    this.noiseOffsetX = 0,
    this.noiseOffsetY = 0,
    this.bands = const [],
    this.sepia = 0,
    this.brightness = 0,
    this.invert = 0,
    this.flash = 0,
    this.vignette = 0,
    this.vignetteRadius = 0,
    this.zoom = 0,
    this.offsetX = 0,
    this.offsetY = 0,
    this.mirrorX = 0,
    this.mirrorY = 0,
    this.tiles = 0,
    this.waveAmplitude = 0,
    this.wavePeriod = 0,
    this.wavePhase = 0,
  });

  /// Reads a frame written by [toList], starting at [offset].
  factory VideoEffectFrame.fromList(List<double> values, [int offset = 0]) {
    final bandCount = values[offset + 8].round().clamp(0, maxBands);
    return VideoEffectFrame(
      pixelSize: values[offset],
      rgbShift: values[offset + 1],
      scanlines: values[offset + 2],
      scanlinePeriod: values[offset + 3],
      noise: values[offset + 4],
      noiseCellSize: values[offset + 5],
      noiseOffsetX: values[offset + 6].round(),
      noiseOffsetY: values[offset + 7].round(),
      bands: [
        for (var i = 0; i < bandCount; i++)
          VideoEffectBand(
            top: values[offset + 9 + i * 3],
            bottom: values[offset + 10 + i * 3],
            shift: values[offset + 11 + i * 3],
          ),
      ],
      sepia: values[offset + _toneOffset],
      brightness: values[offset + _toneOffset + 1],
      invert: values[offset + _toneOffset + 2],
      flash: values[offset + _toneOffset + 3],
      vignette: values[offset + _toneOffset + 4],
      vignetteRadius: values[offset + _toneOffset + 5],
      zoom: values[offset + _geometryOffset],
      offsetX: values[offset + _geometryOffset + 1],
      offsetY: values[offset + _geometryOffset + 2],
      mirrorX: values[offset + _geometryOffset + 3],
      mirrorY: values[offset + _geometryOffset + 4],
      tiles: values[offset + _geometryOffset + 5].round(),
      waveAmplitude: values[offset + _geometryOffset + 6],
      wavePeriod: values[offset + _geometryOffset + 7],
      wavePhase: values[offset + _geometryOffset + 8],
    );
  }

  /// A frame that leaves the picture unchanged.
  static const VideoEffectFrame none = VideoEffectFrame();

  /// The most [bands] a frame carries; renderers ignore any beyond it.
  static const int maxBands = 4;

  /// The edge length of the repeating noise tile, in noise cells.
  static const int noiseTileSize = 128;

  /// The most times [tiles] repeats the picture across and down.
  static const int maxTiles = 2;

  /// The straight segments each wave of [waveAmplitude] is drawn with.
  static const int waveSegments = 16;

  /// The shortest [wavePeriod] renderers draw; a shorter one is drawn this
  /// tall.
  static const double minWavePeriod = 0.1;

  /// Where the tone values start in [toList], after the bands.
  static const int _toneOffset = 9 + maxBands * 3;

  /// Where the geometry values start in [toList], after the tones.
  static const int _geometryOffset = _toneOffset + 6;

  /// The number of values in [toList].
  static const int stride = _geometryOffset + 9;

  /// The edge of a pixelation block, as a fraction of the frame width.
  ///
  /// Blocks start at the top-left corner and each takes the color of the pixel
  /// at its center. A block that rounds to less than two pixels is off.
  final double pixelSize;

  /// How far the red and blue channels move apart, as a fraction of the frame
  /// width.
  ///
  /// Positive values move red to the left and blue to the right; green stays.
  final double rgbShift;

  /// How much the dark scanlines are darkened, from 0 (off) to 1 (black).
  final double scanlines;

  /// The height of one bright plus one dark scanline, as a fraction of the
  /// frame height.
  ///
  /// Rounded to at least two pixels. Within each period the lower half, from
  /// the top edge, is the dark one.
  final double scanlinePeriod;

  /// The strength of the grain: each noise cell brightens or darkens the
  /// picture by up to half this value.
  final double noise;

  /// The edge of a square noise cell, as a fraction of the frame height.
  ///
  /// Rounded to at least one pixel.
  final double noiseCellSize;

  /// Where the repeating noise tile starts, in cells, from 0 to
  /// `noiseTileSize - 1`. Changing it between frames makes the grain move.
  final int noiseOffsetX;

  /// See [noiseOffsetX].
  final int noiseOffsetY;

  /// Horizontal slices of the frame that are shifted sideways.
  ///
  /// Where bands overlap, the first one wins. Renderers use the first
  /// [maxBands] and ignore the rest.
  final List<VideoEffectBand> bands;

  /// How far the colors move towards a sepia tone, from 0 (off) to 1.
  ///
  /// Each pixel becomes `mix(rgb, S * rgb, sepia)`, with the rows of `S` being
  /// `(0.393, 0.769, 0.189)`, `(0.349, 0.686, 0.168)` and
  /// `(0.272, 0.534, 0.131)`.
  final double sepia;

  /// Scales the picture by `1 + brightness`; negative values darken it.
  final double brightness;

  /// How far the colors move towards their negative, from 0 (off) to 1 (fully
  /// inverted): `rgb + invert * (1 - 2 * rgb)`.
  final double invert;

  /// How far the picture fades to white, from 0 (off) to 1 (white):
  /// `rgb + flash * (1 - rgb)`.
  final double flash;

  /// How much the corners are darkened, from 0 (off) to 1 (black).
  ///
  /// Values above 1 turn the corners black before they are reached and push
  /// the black further inward; the colors are clamped at black.
  ///
  /// The darkening follows the frame's shape: with `d` the distance of a pixel
  /// center from the frame center, in half-widths and half-heights, divided by
  /// `sqrt(2)` (so 1 in the corners), and
  /// `t = clamp((d - vignetteRadius) / (1 - vignetteRadius), 0, 1)`, each pixel
  /// is multiplied by `1 - vignette * t * t`.
  final double vignette;

  /// Where the [vignette] starts, as a fraction of the way from the center to
  /// the corners. Renderers clamp it to `0..0.99`.
  final double vignetteRadius;

  /// How far the picture is magnified around the frame center: it is scaled
  /// by `1 + zoom`. Renderers treat a negative value as 0.
  ///
  /// The first geometry stage zooms, moves ([offsetX], [offsetY]) and mirrors
  /// ([mirrorX], [mirrorY]) the picture. With `p` the center of a pixel,
  /// after the mirror, `c` the frame center and `o` the offsets in pixels,
  /// the pixel shows the picture at `(p - c - o) / (1 + zoom) + c`.
  final double zoom;

  /// How far the zoomed picture moves to the right, as a fraction of the
  /// frame width. Negative values move it to the left.
  ///
  /// Where the picture no longer covers the frame its edge pixels repeat; a
  /// [zoom] of at least twice the offset keeps the edges out of view.
  final double offsetX;

  /// How far the zoomed picture moves down, as a fraction of the frame
  /// height. See [offsetX].
  final double offsetY;

  /// How much of the frame, from the right edge, shows the mirror image of
  /// what is left of it: 0.5 mirrors the left half onto the right one.
  ///
  /// Rounded to whole pixels and to at most half the frame width, `m`: from
  /// column `width - m` on, column `x` shows column `2 * (width - m) - 1 - x`.
  final double mirrorX;

  /// How much of the frame, from the bottom edge, shows the mirror image of
  /// what is above it. See [mirrorX].
  final double mirrorY;

  /// How many times the picture repeats across and down: 2 shows it four
  /// times, at half its size, in a 2×2 grid. 0 and 1 are off; renderers treat
  /// anything above [maxTiles] as [maxTiles].
  ///
  /// The second geometry stage: the pixel whose center is `p` shows the
  /// zoomed and mirrored picture at `(p * 2) % size`.
  final int tiles;

  /// How far the rows bend sideways along a wave, as a fraction of the frame
  /// width. Positive values bend the first crest to the right.
  ///
  /// The last geometry stage: the row whose center is `y` pixels below the
  /// top edge moves right by `waveAmplitude * width * w(t)`, with
  /// `t = waveSegments * (y / (wavePeriod * height) + wavePhase)` and `w`
  /// running straight from `sin(2π k / waveSegments)` at every whole
  /// `t = k` to the next: a sine drawn with [waveSegments] straight segments
  /// per wave, which every renderer can draw exactly.
  final double waveAmplitude;

  /// The height of one wave, as a fraction of the frame height. A wave is
  /// off at 0 or less, and drawn at least [minWavePeriod] tall.
  final double wavePeriod;

  /// Where the wave starts, in waves. Raising it between frames rolls the
  /// wave up the picture.
  final double wavePhase;

  /// Whether this frame leaves the picture unchanged.
  bool get isIdentity =>
      pixelSize <= 0 &&
      rgbShift == 0 &&
      scanlines <= 0 &&
      noise <= 0 &&
      bands.every((band) => band.shift == 0 || band.bottom <= band.top) &&
      sepia <= 0 &&
      brightness == 0 &&
      invert <= 0 &&
      flash <= 0 &&
      vignette <= 0 &&
      zoom <= 0 &&
      offsetX == 0 &&
      offsetY == 0 &&
      mirrorX <= 0 &&
      mirrorY <= 0 &&
      tiles < 2 &&
      _waveStrength == 0;

  /// How far the wave bends the rows, or 0 while it is off.
  double get _waveStrength => wavePeriod > 0 ? waveAmplitude.abs() : 0;

  /// Combines this frame with [other], for effects that overlap in time.
  ///
  /// The larger pixelation wins, the channel shifts add up, the stronger
  /// scanlines and the stronger noise win with their own sizes, and the bands
  /// of this frame come before those of [other], up to [maxBands]. Of the
  /// tones, the stronger sepia, invert and flash win, the brightness changes
  /// add up, and the stronger vignette wins with its own radius. Of the
  /// geometry, the zooms and the offsets add up, the larger mirrors and tiles
  /// win, and the stronger wave wins with its own period and phase; a wave
  /// without a period counts as none.
  VideoEffectFrame merge(VideoEffectFrame other) {
    if (other.isIdentity) return this;
    if (isIdentity) return other;
    final strongerScanlines = other.scanlines > scanlines ? other : this;
    final strongerNoise = other.noise > noise ? other : this;
    final strongerVignette = other.vignette > vignette ? other : this;
    final strongerWave = other._waveStrength > _waveStrength ? other : this;
    return VideoEffectFrame(
      pixelSize: math.max(pixelSize, other.pixelSize),
      rgbShift: rgbShift + other.rgbShift,
      scanlines: strongerScanlines.scanlines,
      scanlinePeriod: strongerScanlines.scanlinePeriod,
      noise: strongerNoise.noise,
      noiseCellSize: strongerNoise.noiseCellSize,
      noiseOffsetX: strongerNoise.noiseOffsetX,
      noiseOffsetY: strongerNoise.noiseOffsetY,
      bands: [...bands, ...other.bands].take(maxBands).toList(),
      sepia: math.max(sepia, other.sepia),
      brightness: brightness + other.brightness,
      invert: math.max(invert, other.invert),
      flash: math.max(flash, other.flash),
      vignette: strongerVignette.vignette,
      vignetteRadius: strongerVignette.vignetteRadius,
      zoom: zoom + other.zoom,
      offsetX: offsetX + other.offsetX,
      offsetY: offsetY + other.offsetY,
      mirrorX: math.max(mirrorX, other.mirrorX),
      mirrorY: math.max(mirrorY, other.mirrorY),
      tiles: math.max(tiles, other.tiles),
      waveAmplitude: strongerWave.waveAmplitude,
      wavePeriod: strongerWave.wavePeriod,
      wavePhase: strongerWave.wavePhase,
    );
  }

  /// The flat layout the native renderers read, [stride] values long.
  ///
  /// `pixelSize, rgbShift, scanlines, scanlinePeriod, noise, noiseCellSize,
  /// noiseOffsetX, noiseOffsetY, bandCount`, then `top, bottom, shift` for
  /// each of the [maxBands] bands, zero-filled, then `sepia, brightness,
  /// invert, flash, vignette, vignetteRadius`, then `zoom, offsetX, offsetY,
  /// mirrorX, mirrorY, tiles, waveAmplitude, wavePeriod, wavePhase`.
  List<double> toList() {
    final values = List<double>.filled(stride, 0)
      ..[0] = pixelSize
      ..[1] = rgbShift
      ..[2] = scanlines
      ..[3] = scanlinePeriod
      ..[4] = noise
      ..[5] = noiseCellSize
      ..[6] = noiseOffsetX.toDouble()
      ..[7] = noiseOffsetY.toDouble()
      ..[8] = math.min(bands.length, maxBands).toDouble();
    for (var i = 0; i < math.min(bands.length, maxBands); i++) {
      values[9 + i * 3] = bands[i].top;
      values[10 + i * 3] = bands[i].bottom;
      values[11 + i * 3] = bands[i].shift;
    }
    values
      ..[_toneOffset] = sepia
      ..[_toneOffset + 1] = brightness
      ..[_toneOffset + 2] = invert
      ..[_toneOffset + 3] = flash
      ..[_toneOffset + 4] = vignette
      ..[_toneOffset + 5] = vignetteRadius
      ..[_geometryOffset] = zoom
      ..[_geometryOffset + 1] = offsetX
      ..[_geometryOffset + 2] = offsetY
      ..[_geometryOffset + 3] = mirrorX
      ..[_geometryOffset + 4] = mirrorY
      ..[_geometryOffset + 5] = tiles.toDouble()
      ..[_geometryOffset + 6] = waveAmplitude
      ..[_geometryOffset + 7] = wavePeriod
      ..[_geometryOffset + 8] = wavePhase;
    return values;
  }

  @override
  bool operator ==(Object other) =>
      other is VideoEffectFrame &&
      other.pixelSize == pixelSize &&
      other.rgbShift == rgbShift &&
      other.scanlines == scanlines &&
      other.scanlinePeriod == scanlinePeriod &&
      other.noise == noise &&
      other.noiseCellSize == noiseCellSize &&
      other.noiseOffsetX == noiseOffsetX &&
      other.noiseOffsetY == noiseOffsetY &&
      listEquals(other.bands, bands) &&
      other.sepia == sepia &&
      other.brightness == brightness &&
      other.invert == invert &&
      other.flash == flash &&
      other.vignette == vignette &&
      other.vignetteRadius == vignetteRadius &&
      other.zoom == zoom &&
      other.offsetX == offsetX &&
      other.offsetY == offsetY &&
      other.mirrorX == mirrorX &&
      other.mirrorY == mirrorY &&
      other.tiles == tiles &&
      other.waveAmplitude == waveAmplitude &&
      other.wavePeriod == wavePeriod &&
      other.wavePhase == wavePhase;

  @override
  int get hashCode => Object.hashAll([
    pixelSize,
    rgbShift,
    scanlines,
    scanlinePeriod,
    noise,
    noiseCellSize,
    noiseOffsetX,
    noiseOffsetY,
    Object.hashAll(bands),
    sepia,
    brightness,
    invert,
    flash,
    vignette,
    vignetteRadius,
    zoom,
    offsetX,
    offsetY,
    mirrorX,
    mirrorY,
    tiles,
    waveAmplitude,
    wavePeriod,
    wavePhase,
  ]);

  @override
  String toString() =>
      'VideoEffectFrame(pixelSize: $pixelSize, rgbShift: $rgbShift, '
      'scanlines: $scanlines, scanlinePeriod: $scanlinePeriod, '
      'noise: $noise, noiseCellSize: $noiseCellSize, '
      'noiseOffset: ($noiseOffsetX, $noiseOffsetY), bands: $bands, '
      'sepia: $sepia, brightness: $brightness, invert: $invert, '
      'flash: $flash, vignette: $vignette, vignetteRadius: $vignetteRadius, '
      'zoom: $zoom, offset: ($offsetX, $offsetY), '
      'mirror: ($mirrorX, $mirrorY), tiles: $tiles, '
      'wave: ($waveAmplitude, $wavePeriod, $wavePhase))';
}
