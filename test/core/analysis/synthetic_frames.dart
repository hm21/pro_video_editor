import 'dart:math';
import 'dart:typed_data';

import 'package:pro_video_editor/core/analysis/similarity_transform.dart';

/// A smooth, corner-rich procedural texture that can be sampled at any
/// sub-pixel position, so a rendered frame moves exactly by the transform it
/// was rendered with.
class SyntheticTexture {
  /// Creates a texture from a sum of sine waves with random directions.
  ///
  /// Wavelengths spread log-uniformly from 4 to 160 pixels with an amplitude
  /// that grows with the wavelength, the 1/f spectrum of natural images: the
  /// coarse levels of a pyramid keep enough structure to track on.
  SyntheticTexture({int seed = 1, int waves = 32}) {
    final rng = Random(seed);
    var total = 0.0;
    for (var i = 0; i < waves; i++) {
      final direction = rng.nextDouble() * 2 * pi;
      final wavelength = 4 * pow(40, rng.nextDouble()).toDouble();
      final k = 2 * pi / wavelength;
      _kx.add(k * cos(direction));
      _ky.add(k * sin(direction));
      _phase.add(rng.nextDouble() * 2 * pi);
      _amplitude.add(wavelength);
      total += wavelength * wavelength;
    }
    _norm = 95 / sqrt(total / 2);
  }

  final _kx = <double>[];
  final _ky = <double>[];
  final _phase = <double>[];
  final _amplitude = <double>[];
  late final double _norm;

  /// Intensity at texture position (x, y), roughly 30..225.
  double sample(double x, double y) {
    var v = 0.0;
    for (var i = 0; i < _kx.length; i++) {
      v += _amplitude[i] * sin(_kx[i] * x + _ky[i] * y + _phase[i]);
    }
    return 128 + _norm * v;
  }

  /// Renders a [width] × [height] luma frame showing the texture through
  /// [view], which maps texture coordinates onto centered frame pixels.
  ///
  /// Pixels inside [occluder] (centered frame pixels) show this texture's
  /// content moved by [occluderView] instead, like a subject moving against
  /// the background.
  Uint8List render(
    int width,
    int height,
    SimilarityTransform view, {
    (double, double, double, double)? occluder,
    SimilarityTransform? occluderView,
  }) {
    final out = Uint8List(width * height);
    final inverse = view.inverse();
    final occluderInverse = occluderView?.inverse();
    final cx = (width - 1) / 2;
    final cy = (height - 1) / 2;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final ox = x - cx;
        final oy = y - cy;
        var t = inverse;
        if (occluder != null &&
            occluderInverse != null &&
            ox >= occluder.$1 &&
            oy >= occluder.$2 &&
            ox < occluder.$3 &&
            oy < occluder.$4) {
          t = occluderInverse;
        }
        final v = sample(t.mapX(ox, oy), t.mapY(ox, oy));
        out[y * width + x] = v.round().clamp(0, 255);
      }
    }
    return out;
  }
}
