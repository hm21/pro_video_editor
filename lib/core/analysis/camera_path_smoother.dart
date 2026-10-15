import 'dart:math' as math;
import 'dart:typed_data';

import 'frame_motion_estimator.dart';
import 'similarity_transform.dart';

/// The result of [CameraPathSmoother.plan].
class CameraPathPlan {
  /// Creates a plan.
  const CameraPathPlan({
    required this.zoom,
    required this.warps,
    required this.attenuatedFrames,
    required this.unreliableFrames,
  });

  /// The zoom every frame is scaled by to keep the borders out of view.
  final double zoom;

  /// One warp per frame, mapping the source frame onto the steadied output
  /// in pixels centered on the frame. [zoom] is already included.
  final List<SimilarityTransform> warps;

  /// Frames whose correction was reduced to stay within the zoom limit.
  final int attenuatedFrames;

  /// Frame pairs whose motion could not be measured and was interpolated.
  final int unreliableFrames;
}

/// Turns measured frame-to-frame motion into a steadier camera path.
///
/// The camera path is the accumulated motion since the first frame. It is
/// smoothed with a Gaussian, and each frame is warped from the real path
/// onto the smooth one. Warping exposes the frame's border, which a constant
/// zoom hides.
///
/// Where the full correction would need more zoom than [maxZoom], the path
/// is pulled back towards the real one, so the clip keeps some shake rather
/// than being cropped deeper. How far it is pulled back changes gradually
/// over [smoothingFrames], never from one frame to the next, so the limit
/// cannot add jolts of its own.
class CameraPathSmoother {
  /// Creates a smoother.
  const CameraPathSmoother({this.smoothingFrames = 30, this.maxZoom = 1.15});

  /// Standard deviation of the smoothing, in frames.
  final double smoothingFrames;

  /// The largest zoom the result may use.
  final double maxZoom;

  /// Plans warps for `motions.length + 1` frames of [width] × [height].
  CameraPathPlan plan(List<FrameMotion> motions, int width, int height) {
    final n = motions.length + 1;
    final deltas = _fillGaps(motions);

    // Camera path: frame 0 -> frame t, as (tx, ty, angle, log scale). Angle
    // and scale add up exactly, so they are summed to keep the angle from
    // wrapping.
    var current = SimilarityTransform.identity;
    final real = List.generate(4, (_) => Float64List(n));
    for (var t = 1; t < n; t++) {
      final d = deltas[t - 1];
      current = current.then(d);
      real[0][t] = current.tx;
      real[1][t] = current.ty;
      real[2][t] = real[2][t - 1] + d.angle;
      real[3][t] = real[3][t - 1] + d.logScale;
    }
    final smooth = [for (final p in real) _gaussian(p, smoothingFrames)];

    final hw = width / 2;
    final hh = height / 2;

    /// The correction for frame [t] when the path moves [shift] of the way
    /// from the real path to the smooth one in position and [turn] of the
    /// way in rotation and scale.
    SimilarityTransform correction(int t, double shift, double turn) {
      final steady = SimilarityTransform.fromParams(
        tx: real[0][t] + shift * (smooth[0][t] - real[0][t]),
        ty: real[1][t] + shift * (smooth[1][t] - real[1][t]),
        angle: real[2][t] + turn * (smooth[2][t] - real[2][t]),
        logScale: real[3][t] + turn * (smooth[3][t] - real[3][t]),
      );
      final actual = SimilarityTransform.fromParams(
        tx: real[0][t],
        ty: real[1][t],
        angle: real[2][t],
        logScale: real[3][t],
      );
      return actual.inverse().then(steady);
    }

    final radius = math.max(1, (smoothingFrames / 2).round());

    // The strongest correction each frame allows on its own, eased over
    // time: a minimum over ±radius followed by a blur no wider than that
    // radius never exceeds what any frame allows.
    final allowed = Float64List(n);
    for (var t = 0; t < n; t++) {
      allowed[t] = _maxStrength((k) => correction(t, k, k), hw, hh);
    }
    final shift = _blurWithin(_minimumFilter(allowed, radius), radius);

    // Rotation shake reads strongly, so the turn takes whatever margin the
    // shift leaves, eased the same way.
    final turnAllowed = Float64List(n);
    for (var t = 0; t < n; t++) {
      turnAllowed[t] = _maxStrength((k) => correction(t, shift[t], k), hw, hh);
    }
    final turn = _blurWithin(_minimumFilter(turnAllowed, radius), radius);

    final corrections = <SimilarityTransform>[];
    var attenuated = 0;
    for (var t = 0; t < n; t++) {
      var s = math.min(shift[t], allowed[t]);
      var r = math.max(s, math.min(turn[t], turnAllowed[t]));
      if (!_covers(correction(t, s, r), maxZoom, hw, hh)) {
        // Easing both kept each within its own limit but not together.
        s = r = _maxStrength((k) => correction(t, s * k, r * k), hw, hh);
      }
      if (s < 0.999 || r < 0.999) attenuated++;
      corrections.add(correction(t, s, r));
    }

    var zoom = 1.0;
    for (final c in corrections) {
      zoom = math.max(zoom, _minZoom(c, hw, hh));
    }
    zoom = math.min(zoom, maxZoom);
    final zoomTransform = SimilarityTransform(zoom, 0, 0, 0);
    return CameraPathPlan(
      zoom: zoom,
      warps: [for (final c in corrections) c.then(zoomTransform)],
      attenuatedFrames: attenuated,
      unreliableFrames: motions.where((m) => m.transform == null).length,
    );
  }

  /// Replaces unmeasured motions with the mean of their nearest measured
  /// neighbours, so a blurred frame does not read as the camera stopping.
  static List<SimilarityTransform> _fillGaps(List<FrameMotion> motions) {
    final out = <SimilarityTransform>[];
    for (var i = 0; i < motions.length; i++) {
      final own = motions[i].transform;
      if (own != null) {
        out.add(own);
        continue;
      }
      SimilarityTransform? before;
      SimilarityTransform? after;
      for (var j = i - 1; j >= 0 && before == null; j--) {
        before = motions[j].transform;
      }
      for (var j = i + 1; j < motions.length && after == null; j++) {
        after = motions[j].transform;
      }
      if (before != null && after != null) {
        out.add(
          SimilarityTransform(
            (before.a + after.a) / 2,
            (before.b + after.b) / 2,
            (before.tx + after.tx) / 2,
            (before.ty + after.ty) / 2,
          ),
        );
      } else {
        out.add(before ?? after ?? SimilarityTransform.identity);
      }
    }
    return out;
  }

  /// Whether the output frame, zoomed by [zoom], lies inside the source
  /// frame after [warp].
  bool _covers(SimilarityTransform warp, double zoom, double hw, double hh) {
    final inverse = warp.inverse();
    const epsilon = 1e-6;
    for (final (ox, oy) in [(-hw, -hh), (hw, -hh), (-hw, hh), (hw, hh)]) {
      final x = inverse.mapX(ox / zoom, oy / zoom);
      final y = inverse.mapY(ox / zoom, oy / zoom);
      if (x.abs() > hw + epsilon || y.abs() > hh + epsilon) return false;
    }
    return true;
  }

  double _minZoom(SimilarityTransform warp, double hw, double hh) {
    if (_covers(warp, 1, hw, hh)) return 1;
    var lo = 1.0;
    var hi = 4.0;
    for (var i = 0; i < 30; i++) {
      final mid = (lo + hi) / 2;
      if (_covers(warp, mid, hw, hh)) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    return hi;
  }

  /// The largest strength in `0..1` whose [correction] still fits at
  /// [maxZoom].
  double _maxStrength(
    SimilarityTransform Function(double strength) correction,
    double hw,
    double hh,
  ) {
    if (_covers(correction(1), maxZoom, hw, hh)) return 1;
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
      final mid = (lo + hi) / 2;
      if (_covers(correction(mid), maxZoom, hw, hh)) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static Float64List _minimumFilter(Float64List v, int radius) {
    final n = v.length;
    final out = Float64List(n);
    for (var t = 0; t < n; t++) {
      var m = v[t];
      for (
        var k = math.max(0, t - radius);
        k <= math.min(n - 1, t + radius);
        k++
      ) {
        if (v[k] < m) m = v[k];
      }
      out[t] = m;
    }
    return out;
  }

  /// Gaussian blur truncated at [radius], with the ends held.
  static Float64List _blurWithin(Float64List v, int radius) {
    final n = v.length;
    final sigma = radius / 3;
    final out = Float64List(n);
    for (var t = 0; t < n; t++) {
      var acc = 0.0;
      var sum = 0.0;
      for (var k = -radius; k <= radius; k++) {
        final w = math.exp(-(k * k) / (2 * sigma * sigma));
        acc += w * v[(t + k).clamp(0, n - 1)];
        sum += w;
      }
      out[t] = acc / sum;
    }
    return out;
  }

  /// Gaussian smoothing with odd reflection at both ends, so a pan that is
  /// still moving at the first or last frame keeps its direction instead of
  /// bending towards a standstill.
  static Float64List _gaussian(Float64List v, double s) {
    final n = v.length;
    if (n < 2 || s <= 0) return Float64List.fromList(v);
    final radius = (s * 3).ceil();
    final kernel = Float64List(2 * radius + 1);
    var sum = 0.0;
    for (var i = -radius; i <= radius; i++) {
      final k = math.exp(-(i * i) / (2 * s * s));
      kernel[i + radius] = k;
      sum += k;
    }
    double at(int i) {
      if (i < 0) return 2 * v[0] - v[math.min(-i, n - 1)];
      if (i >= n) return 2 * v[n - 1] - v[math.max(2 * (n - 1) - i, 0)];
      return v[i];
    }

    final out = Float64List(n);
    for (var t = 0; t < n; t++) {
      var acc = 0.0;
      for (var k = -radius; k <= radius; k++) {
        acc += kernel[k + radius] * at(t + k);
      }
      out[t] = acc / sum;
    }
    return out;
  }
}
