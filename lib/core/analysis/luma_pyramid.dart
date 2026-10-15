import 'dart:typed_data';

/// One level of a [LumaPyramid]: intensities plus their Scharr gradients.
class LumaPyramidLevel {
  /// Creates a level from [pixels] and computes its gradients.
  LumaPyramidLevel(this.width, this.height, this.pixels)
    : gx = Float32List(width * height),
      gy = Float32List(width * height) {
    _computeGradients();
  }

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Row-major intensities, `0..255`.
  final Float32List pixels;

  /// Horizontal intensity gradient per pixel.
  final Float32List gx;

  /// Vertical intensity gradient per pixel.
  final Float32List gy;

  void _computeGradients() {
    final w = width;
    final h = height;
    final p = pixels;
    for (var y = 0; y < h; y++) {
      final ym = (y == 0 ? 0 : y - 1) * w;
      final y0 = y * w;
      final yp = (y == h - 1 ? h - 1 : y + 1) * w;
      for (var x = 0; x < w; x++) {
        final xm = x == 0 ? 0 : x - 1;
        final xp = x == w - 1 ? w - 1 : x + 1;
        gx[y0 + x] =
            (3 * (p[ym + xp] - p[ym + xm]) +
                10 * (p[y0 + xp] - p[y0 + xm]) +
                3 * (p[yp + xp] - p[yp + xm])) /
            32;
        gy[y0 + x] =
            (3 * (p[yp + xm] - p[ym + xm]) +
                10 * (p[yp + x] - p[ym + x]) +
                3 * (p[yp + xp] - p[ym + xp])) /
            32;
      }
    }
  }
}

/// A Gaussian pyramid of a luma frame, each level half the size of the one
/// before, with the gradients point tracking needs.
class LumaPyramid {
  LumaPyramid._(this.levels);

  /// Builds up to [levelCount] levels from a row-major 8-bit luma frame.
  /// Levels smaller than 16 pixels on a side are not built.
  factory LumaPyramid.fromLuma(
    Uint8List luma,
    int width,
    int height, {
    int levelCount = 3,
  }) {
    final base = Float32List(width * height);
    for (var i = 0; i < base.length; i++) {
      base[i] = luma[i].toDouble();
    }
    final levels = <LumaPyramidLevel>[LumaPyramidLevel(width, height, base)];
    var w = width;
    var h = height;
    var src = base;
    for (var l = 1; l < levelCount; l++) {
      final nw = (w + 1) >> 1;
      final nh = (h + 1) >> 1;
      if (nw < 16 || nh < 16) break;
      final dst = _downsample(src, w, h, nw, nh);
      levels.add(LumaPyramidLevel(nw, nh, dst));
      src = dst;
      w = nw;
      h = nh;
    }
    return LumaPyramid._(levels);
  }

  /// The levels, full resolution first.
  final List<LumaPyramidLevel> levels;

  /// 5-tap binomial blur, then every second pixel.
  static Float32List _downsample(
    Float32List src,
    int w,
    int h,
    int nw,
    int nh,
  ) {
    final tmp = Float32List(nw * h);
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var nx = 0; nx < nw; nx++) {
        final x = nx * 2;
        final x0 = x - 2 < 0 ? 0 : x - 2;
        final x1 = x - 1 < 0 ? 0 : x - 1;
        final x3 = x + 1 >= w ? w - 1 : x + 1;
        final x4 = x + 2 >= w ? w - 1 : x + 2;
        final xc = x >= w ? w - 1 : x;
        tmp[y * nw + nx] =
            (src[row + x0] +
                4 * src[row + x1] +
                6 * src[row + xc] +
                4 * src[row + x3] +
                src[row + x4]) /
            16;
      }
    }
    final dst = Float32List(nw * nh);
    for (var ny = 0; ny < nh; ny++) {
      final y = ny * 2;
      final y0 = (y - 2 < 0 ? 0 : y - 2) * nw;
      final y1 = (y - 1 < 0 ? 0 : y - 1) * nw;
      final yc = (y >= h ? h - 1 : y) * nw;
      final y3 = (y + 1 >= h ? h - 1 : y + 1) * nw;
      final y4 = (y + 2 >= h ? h - 1 : y + 2) * nw;
      for (var nx = 0; nx < nw; nx++) {
        dst[ny * nw + nx] =
            (tmp[y0 + nx] +
                4 * tmp[y1 + nx] +
                6 * tmp[yc + nx] +
                4 * tmp[y3 + nx] +
                tmp[y4 + nx]) /
            16;
      }
    }
    return dst;
  }
}
