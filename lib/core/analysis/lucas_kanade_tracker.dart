import 'dart:math' as math;
import 'dart:typed_data';

import 'luma_pyramid.dart';

/// Pyramidal Lucas-Kanade point tracker (Bouguet's formulation).
///
/// Each point is refined from the coarsest pyramid level down, so motions
/// larger than the window still converge.
class LucasKanadeTracker {
  /// Creates a tracker with a `(2·radius + 1)²` window.
  LucasKanadeTracker({
    this.radius = 4,
    this.maxIterations = 10,
    this.epsilon = 0.02,
  }) : _wI = Float32List((2 * radius + 1) * (2 * radius + 1)),
       _wGx = Float32List((2 * radius + 1) * (2 * radius + 1)),
       _wGy = Float32List((2 * radius + 1) * (2 * radius + 1));

  /// Half the window size in pixels.
  final int radius;

  /// Iteration cap per pyramid level.
  final int maxIterations;

  /// Iterations stop once an update moves the point less than this, in
  /// pixels of the current level.
  final double epsilon;

  final Float32List _wI;
  final Float32List _wGx;
  final Float32List _wGy;

  /// Tracks [points] (interleaved x, y in level-0 pixels) from [prev] to
  /// [next]. Writes the tracked positions to [out] and returns a mask of
  /// points that were tracked successfully. [guess] holds predicted
  /// positions in [next], e.g. from the previous frame's motion.
  Uint8List track(
    LumaPyramid prev,
    LumaPyramid next,
    Float32List points,
    Float32List out, {
    Float32List? guess,
  }) {
    final count = points.length >> 1;
    final ok = Uint8List(count);
    final top = prev.levels.length - 1;
    for (var p = 0; p < count; p++) {
      final px = points[2 * p];
      final py = points[2 * p + 1];
      final top0 = 1.0 / (1 << top);
      var gx = guess == null ? 0.0 : (guess[2 * p] - px) * top0;
      var gy = guess == null ? 0.0 : (guess[2 * p + 1] - py) * top0;
      var lost = false;
      for (var l = top; l >= 0; l--) {
        final scale = 1.0 / (1 << l);
        final lx = px * scale;
        final ly = py * scale;
        var res = _trackLevel(prev.levels[l], next.levels[l], lx, ly, gx, gy);
        if (res == null) {
          if (l == 0) {
            lost = true;
            break;
          }
          // No answer at a coarse level (a flat window, or the point left
          // the image there): carry the estimate down unchanged.
          res = (0.0, 0.0);
        }
        if (l > 0) {
          gx = 2 * (gx + res.$1);
          gy = 2 * (gy + res.$2);
        } else {
          gx += res.$1;
          gy += res.$2;
        }
      }
      final nx = px + gx;
      final ny = py + gy;
      final base = next.levels[0];
      if (lost ||
          nx < radius ||
          ny < radius ||
          nx > base.width - 1 - radius ||
          ny > base.height - 1 - radius) {
        out[2 * p] = px;
        out[2 * p + 1] = py;
        continue;
      }
      out[2 * p] = nx;
      out[2 * p + 1] = ny;
      ok[p] = 1;
    }
    return ok;
  }

  /// Refines the displacement of the point (x, y) between levels [a] and
  /// [b], starting from the guess (gx, gy). Windows that reach past the edge
  /// read the nearest edge pixels, so points close to the border of a small,
  /// coarse level still contribute.
  (double, double)? _trackLevel(
    LumaPyramidLevel a,
    LumaPyramidLevel b,
    double x,
    double y,
    double gx,
    double gy,
  ) {
    final r = radius;
    final w = a.width;
    final h = a.height;
    if (x < 0 || y < 0 || x > w - 1 || y > h - 1) return null;

    // Sample the template window and its gradients once.
    var gxx = 0.0;
    var gyy = 0.0;
    var gxy = 0.0;
    final ix0 = x.floor();
    final iy0 = y.floor();
    final fx = x - ix0;
    final fy = y - iy0;
    final w00 = (1 - fx) * (1 - fy);
    final w10 = fx * (1 - fy);
    final w01 = (1 - fx) * fy;
    final w11 = fx * fy;
    var k = 0;
    for (var dy = -r; dy <= r; dy++) {
      final row = _clamp(iy0 + dy, h) * w;
      final rowBelow = _clamp(iy0 + dy + 1, h) * w;
      for (var dx = -r; dx <= r; dx++) {
        final c0 = _clamp(ix0 + dx, w);
        final c1 = _clamp(ix0 + dx + 1, w);
        final i00 = row + c0, i10 = row + c1;
        final i01 = rowBelow + c0, i11 = rowBelow + c1;
        final ggx =
            w00 * a.gx[i00] +
            w10 * a.gx[i10] +
            w01 * a.gx[i01] +
            w11 * a.gx[i11];
        final ggy =
            w00 * a.gy[i00] +
            w10 * a.gy[i10] +
            w01 * a.gy[i01] +
            w11 * a.gy[i11];
        _wI[k] =
            w00 * a.pixels[i00] +
            w10 * a.pixels[i10] +
            w01 * a.pixels[i01] +
            w11 * a.pixels[i11];
        _wGx[k] = ggx;
        _wGy[k] = ggy;
        gxx += ggx * ggx;
        gyy += ggy * ggy;
        gxy += ggx * ggy;
        k++;
      }
    }
    final det = gxx * gyy - gxy * gxy;
    // Minimum eigenvalue check: reject flat or edge-only windows.
    final tr = (gxx + gyy) * 0.5;
    final disc = (gxx - gyy) * 0.5;
    final minEig = tr - math.sqrt(disc * disc + gxy * gxy);
    if (minEig / k < 1e-2 || det.abs() < 1e-9) return null;
    final invDet = 1 / det;

    var vx = 0.0;
    var vy = 0.0;
    final bw = b.width;
    final bh = b.height;
    for (var it = 0; it < maxIterations; it++) {
      final qx = x + gx + vx;
      final qy = y + gy + vy;
      if (qx < 0 || qy < 0 || qx > bw - 1 || qy > bh - 1) return null;
      final jx0 = qx.floor();
      final jy0 = qy.floor();
      final qfx = qx - jx0;
      final qfy = qy - jy0;
      final q00 = (1 - qfx) * (1 - qfy);
      final q10 = qfx * (1 - qfy);
      final q01 = (1 - qfx) * qfy;
      final q11 = qfx * qfy;
      var bx = 0.0;
      var by = 0.0;
      k = 0;
      for (var dy = -r; dy <= r; dy++) {
        final row = _clamp(jy0 + dy, bh) * bw;
        final rowBelow = _clamp(jy0 + dy + 1, bh) * bw;
        for (var dx = -r; dx <= r; dx++) {
          final c0 = _clamp(jx0 + dx, bw);
          final c1 = _clamp(jx0 + dx + 1, bw);
          final v =
              q00 * b.pixels[row + c0] +
              q10 * b.pixels[row + c1] +
              q01 * b.pixels[rowBelow + c0] +
              q11 * b.pixels[rowBelow + c1];
          final diff = _wI[k] - v;
          bx += diff * _wGx[k];
          by += diff * _wGy[k];
          k++;
        }
      }
      final ex = (gyy * bx - gxy * by) * invDet;
      final ey = (gxx * by - gxy * bx) * invDet;
      vx += ex;
      vy += ey;
      if (ex * ex + ey * ey < epsilon * epsilon) break;
    }
    return (vx, vy);
  }

  static int _clamp(int i, int size) => i < 0 ? 0 : (i >= size ? size - 1 : i);
}
