import 'dart:math' as math;
import 'dart:typed_data';

import 'luma_pyramid.dart';

/// Finds Shi-Tomasi corners in [level], spread over a grid of
/// [gridColumns] × [gridRows] cells with at most [perCell] corners each, so
/// a single textured region cannot take all the points.
///
/// Corners weaker than [qualityLevel] times the strongest one are dropped,
/// and none are placed within [border] pixels of the edge.
///
/// Returns interleaved `x, y` coordinates.
Float32List detectCorners(
  LumaPyramidLevel level, {
  int gridColumns = 8,
  int gridRows = 8,
  int perCell = 3,
  double qualityLevel = 0.02,
  int border = 8,
}) {
  final w = level.width;
  final h = level.height;
  final gx = level.gx;
  final gy = level.gy;
  final n = w * h;
  final xx = Float32List(n);
  final yy = Float32List(n);
  final xy = Float32List(n);
  for (var i = 0; i < n; i++) {
    final a = gx[i];
    final b = gy[i];
    xx[i] = a * a;
    yy[i] = b * b;
    xy[i] = a * b;
  }
  _boxBlur5(xx, w, h);
  _boxBlur5(yy, w, h);
  _boxBlur5(xy, w, h);

  final response = Float32List(n);
  var maxResponse = 0.0;
  for (var y = border; y < h - border; y++) {
    for (var x = border; x < w - border; x++) {
      final i = y * w + x;
      final a = xx[i];
      final c = yy[i];
      final b = xy[i];
      final half = (a - c) * 0.5;
      final r = (a + c) * 0.5 - math.sqrt(half * half + b * b);
      response[i] = r;
      if (r > maxResponse) maxResponse = r;
    }
  }
  final threshold = maxResponse * qualityLevel;
  if (maxResponse <= 0) return Float32List(0);

  final out = <double>[];
  final cellW = (w - 2 * border) / gridColumns;
  final cellH = (h - 2 * border) / gridRows;
  final minDist = math.max(3, (math.min(cellW, cellH) / 3).floor());
  final minDist2 = minDist * minDist;
  final candidates = <int>[];
  final picked = <int>[];
  for (var gyIdx = 0; gyIdx < gridRows; gyIdx++) {
    final y0 = border + (gyIdx * cellH).floor();
    final y1 = border + ((gyIdx + 1) * cellH).floor();
    for (var gxIdx = 0; gxIdx < gridColumns; gxIdx++) {
      final x0 = border + (gxIdx * cellW).floor();
      final x1 = border + ((gxIdx + 1) * cellW).floor();
      candidates.clear();
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final i = y * w + x;
          final r = response[i];
          if (r < threshold) continue;
          // 3x3 local maximum only.
          if (r < response[i - 1] ||
              r < response[i + 1] ||
              r < response[i - w] ||
              r < response[i + w] ||
              r < response[i - w - 1] ||
              r < response[i - w + 1] ||
              r < response[i + w - 1] ||
              r < response[i + w + 1]) {
            continue;
          }
          candidates.add(i);
        }
      }
      candidates.sort((p, q) => response[q].compareTo(response[p]));
      picked.clear();
      for (final i in candidates) {
        final x = i % w;
        final y = i ~/ w;
        var ok = true;
        for (final j in picked) {
          final dx = (j % w) - x;
          final dy = (j ~/ w) - y;
          if (dx * dx + dy * dy < minDist2) {
            ok = false;
            break;
          }
        }
        if (!ok) continue;
        picked.add(i);
        out
          ..add(x.toDouble())
          ..add(y.toDouble());
        if (picked.length >= perCell) break;
      }
    }
  }
  return Float32List.fromList(out);
}

/// 5x5 box sum with running sums and clamped borders.
void _boxBlur5(Float32List data, int w, int h) {
  final tmp = Float32List(data.length);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var s = 3 * data[row] + data[row + 1] + data[row + 2];
    for (var x = 0; x < w; x++) {
      tmp[row + x] = s;
      final add = x + 3 < w ? x + 3 : w - 1;
      final sub = x - 2 > 0 ? x - 2 : 0;
      s += data[row + add] - data[row + sub];
    }
  }
  for (var x = 0; x < w; x++) {
    var s = 3 * tmp[x] + tmp[w + x] + tmp[2 * w + x];
    for (var y = 0; y < h; y++) {
      data[y * w + x] = s;
      final add = y + 3 < h ? y + 3 : h - 1;
      final sub = y - 2 > 0 ? y - 2 : 0;
      s += tmp[add * w + x] - tmp[sub * w + x];
    }
  }
}
