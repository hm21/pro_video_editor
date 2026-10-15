import 'dart:typed_data';

import 'similarity_transform.dart';

/// Result of a robust fit between two point sets.
class SimilarityFit {
  /// Creates a fit result.
  const SimilarityFit(this.transform, this.inliers, this.total);

  /// The transform that maps the source points onto the destination points.
  final SimilarityTransform transform;

  /// How many point pairs agree with [transform].
  final int inliers;

  /// How many point pairs were offered.
  final int total;
}

/// Fits a similarity transform mapping [src] onto [dst] (interleaved `x, y`,
/// [count] pairs) with RANSAC on two-point samples, then refines it by least
/// squares on the pairs within [threshold] pixels.
///
/// The sampling is seeded, so the same input always gives the same result.
/// Returns null when fewer than [minInliers] pairs agree on one motion.
SimilarityFit? fitSimilarityRansac(
  Float32List src,
  Float32List dst,
  int count, {
  double threshold = 1.0,
  int iterations = 64,
  int minInliers = 8,
  int seed = 0x9E3779B9,
}) {
  if (count < 2) return null;
  var rng = seed;
  int nextInt(int max) {
    rng = (rng * 1103515245 + 12345) & 0x7fffffff;
    return rng % max;
  }

  final th2 = threshold * threshold;
  var bestCount = 0;
  SimilarityTransform? best;
  for (var it = 0; it < iterations; it++) {
    final i = nextInt(count);
    var j = nextInt(count);
    if (j == i) j = (j + 1) % count;
    final m = _fromTwoPoints(src, dst, i, j);
    if (m == null) continue;
    // Reject wild hypotheses early: inter-frame motion is small.
    final s = m.scale;
    if (s < 0.8 || s > 1.25) continue;
    var c = 0;
    for (var k = 0; k < count; k++) {
      final x = src[2 * k];
      final y = src[2 * k + 1];
      final ex = m.mapX(x, y) - dst[2 * k];
      final ey = m.mapY(x, y) - dst[2 * k + 1];
      if (ex * ex + ey * ey < th2) c++;
    }
    if (c > bestCount) {
      bestCount = c;
      best = m;
    }
  }
  if (best == null || bestCount < minInliers) return null;

  // Two refinement rounds on the inlier set.
  var model = best;
  var inliers = bestCount;
  final mask = Uint8List(count);
  for (var round = 0; round < 2; round++) {
    inliers = 0;
    for (var k = 0; k < count; k++) {
      final x = src[2 * k];
      final y = src[2 * k + 1];
      final ex = model.mapX(x, y) - dst[2 * k];
      final ey = model.mapY(x, y) - dst[2 * k + 1];
      final inl = ex * ex + ey * ey < th2;
      mask[k] = inl ? 1 : 0;
      if (inl) inliers++;
    }
    if (inliers < minInliers) return null;
    model = fitSimilarityLeastSquares(src, dst, count, mask) ?? model;
  }
  return SimilarityFit(model, inliers, count);
}

SimilarityTransform? _fromTwoPoints(
  Float32List src,
  Float32List dst,
  int i,
  int j,
) {
  final x1 = src[2 * i], y1 = src[2 * i + 1];
  final x2 = src[2 * j], y2 = src[2 * j + 1];
  final u1 = dst[2 * i], v1 = dst[2 * i + 1];
  final u2 = dst[2 * j], v2 = dst[2 * j + 1];
  final dx = x2 - x1, dy = y2 - y1;
  final du = u2 - u1, dv = v2 - v1;
  final d = dx * dx + dy * dy;
  if (d < 25) return null; // Points closer than 5 px give unstable rotation.
  // (du + i dv) = (a + i b)(dx + i dy)
  final a = (du * dx + dv * dy) / d;
  final b = (dv * dx - du * dy) / d;
  final tx = u1 - (a * x1 - b * y1);
  final ty = v1 - (b * x1 + a * y1);
  return SimilarityTransform(a, b, tx, ty);
}

/// Closed-form least-squares similarity over points where [mask] is set.
SimilarityTransform? fitSimilarityLeastSquares(
  Float32List src,
  Float32List dst,
  int count,
  Uint8List? mask,
) {
  var n = 0;
  var sx = 0.0, sy = 0.0, su = 0.0, sv = 0.0;
  for (var k = 0; k < count; k++) {
    if (mask != null && mask[k] == 0) continue;
    sx += src[2 * k];
    sy += src[2 * k + 1];
    su += dst[2 * k];
    sv += dst[2 * k + 1];
    n++;
  }
  if (n < 2) return null;
  final mx = sx / n, my = sy / n, mu = su / n, mv = sv / n;
  var num1 = 0.0, num2 = 0.0, den = 0.0;
  for (var k = 0; k < count; k++) {
    if (mask != null && mask[k] == 0) continue;
    final x = src[2 * k] - mx;
    final y = src[2 * k + 1] - my;
    final u = dst[2 * k] - mu;
    final v = dst[2 * k + 1] - mv;
    num1 += x * u + y * v;
    num2 += x * v - y * u;
    den += x * x + y * y;
  }
  if (den < 1e-9) return null;
  final a = num1 / den;
  final b = num2 / den;
  return SimilarityTransform(
    a,
    b,
    mu - (a * mx - b * my),
    mv - (b * mx + a * my),
  );
}
