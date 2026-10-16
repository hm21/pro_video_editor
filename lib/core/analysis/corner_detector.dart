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

/// Finds Shi-Tomasi corners of [level] inside the rect from ([left], [top])
/// to ([right], [bottom]), in the level's pixels, spread over a grid of
/// [gridColumns] × [gridRows] cells with at most [perCell] corners each.
///
/// Unlike [detectCorners], only the rect is measured, and corners are
/// compared with the strongest one inside it: a small region on a busy frame
/// keeps its own corners. Corners weaker than [qualityLevel] times that one
/// are dropped, and none are placed within [border] pixels of the frame edge.
///
/// Returns interleaved `x, y` coordinates.
Float32List detectCornersInRect(
  LumaPyramidLevel level, {
  required double left,
  required double top,
  required double right,
  required double bottom,
  int gridColumns = 4,
  int gridRows = 4,
  int perCell = 4,
  double qualityLevel = 0.01,
  int border = 8,
}) {
  final w = level.width;
  final h = level.height;
  final x0 = math.max(border, left.ceil());
  final y0 = math.max(border, top.ceil());
  final x1 = math.min(w - border, right.floor());
  final y1 = math.min(h - border, bottom.floor());
  if (x1 - x0 < 3 || y1 - y0 < 3) return Float32List(0);

  // The structure tensor is summed over 5x5 windows, so it needs two more
  // pixels on every side of the rect.
  final ax0 = math.max(0, x0 - 3);
  final ay0 = math.max(0, y0 - 3);
  final ax1 = math.min(w, x1 + 3);
  final ay1 = math.min(h, y1 + 3);
  final rw = ax1 - ax0;
  final rh = ay1 - ay0;
  final xx = Float32List(rw * rh);
  final yy = Float32List(rw * rh);
  final xy = Float32List(rw * rh);
  for (var y = 0; y < rh; y++) {
    final src = (ay0 + y) * w + ax0;
    final dst = y * rw;
    for (var x = 0; x < rw; x++) {
      final a = level.gx[src + x];
      final b = level.gy[src + x];
      xx[dst + x] = a * a;
      yy[dst + x] = b * b;
      xy[dst + x] = a * b;
    }
  }
  _boxBlur5(xx, rw, rh);
  _boxBlur5(yy, rw, rh);
  _boxBlur5(xy, rw, rh);

  final response = Float32List(rw * rh);
  var maxResponse = 0.0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final i = (y - ay0) * rw + (x - ax0);
      final a = xx[i];
      final c = yy[i];
      final b = xy[i];
      final half = (a - c) * 0.5;
      final r = (a + c) * 0.5 - math.sqrt(half * half + b * b);
      response[i] = r;
      if (r > maxResponse) maxResponse = r;
    }
  }
  if (maxResponse <= 0) return Float32List(0);
  final threshold = maxResponse * qualityLevel;

  final out = <double>[];
  final cellW = (x1 - x0) / gridColumns;
  final cellH = (y1 - y0) / gridRows;
  final minDist = math.max(2, (math.min(cellW, cellH) / 3).floor());
  final minDist2 = minDist * minDist;
  final candidates = <int>[];
  final picked = <int>[];
  for (var row = 0; row < gridRows; row++) {
    final cy0 = y0 + (row * cellH).floor();
    final cy1 = y0 + ((row + 1) * cellH).floor();
    for (var column = 0; column < gridColumns; column++) {
      final cx0 = x0 + (column * cellW).floor();
      final cx1 = x0 + ((column + 1) * cellW).floor();
      candidates.clear();
      for (var y = cy0; y < cy1; y++) {
        for (var x = cx0; x < cx1; x++) {
          final i = (y - ay0) * rw + (x - ax0);
          final r = response[i];
          if (r < threshold) continue;
          // 3x3 local maximum only; the rect's own edge pixels compare with
          // neighbours that were never measured and stay 0.
          if (r < response[i - 1] ||
              r < response[i + 1] ||
              r < response[i - rw] ||
              r < response[i + rw] ||
              r < response[i - rw - 1] ||
              r < response[i - rw + 1] ||
              r < response[i + rw - 1] ||
              r < response[i + rw + 1]) {
            continue;
          }
          candidates.add(i);
        }
      }
      candidates.sort((p, q) => response[q].compareTo(response[p]));
      picked.clear();
      for (final i in candidates) {
        final x = i % rw;
        final y = i ~/ rw;
        var ok = true;
        for (final j in picked) {
          final dx = (j % rw) - x;
          final dy = (j ~/ rw) - y;
          if (dx * dx + dy * dy < minDist2) {
            ok = false;
            break;
          }
        }
        if (!ok) continue;
        picked.add(i);
        out
          ..add((x + ax0).toDouble())
          ..add((y + ay0).toDouble());
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
