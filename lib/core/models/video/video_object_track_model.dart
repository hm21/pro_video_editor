import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

/// Where a tracked object is in one frame.
///
/// Everything is measured in the frame's own upright pixel space, the way
/// the video is displayed, as fractions of its width and height: `(0, 0)` is
/// the top left corner, `(1, 1)` the bottom right one.
@immutable
class ObjectTrackSample {
  /// Creates an [ObjectTrackSample].
  const ObjectTrackSample({
    required this.time,
    required this.center,
    required this.size,
    this.scale = 1,
    this.rotation = 0,
  }) : assert(scale > 0, '[scale] must be positive');

  /// The source timestamp of the frame: the position in the video file, not
  /// on a rendered timeline.
  final Duration time;

  /// The middle of the tracked region, as a fraction of the frame's width
  /// (dx) and height (dy).
  final Offset center;

  /// The width and height of the tracked region, as fractions of the frame's
  /// width and height.
  final Size size;

  /// How much larger the object shows than in the frame it was marked on.
  final double scale;

  /// How far the object turned since the frame it was marked on, in radians,
  /// clockwise on screen.
  final double rotation;

  /// The tracked region, as fractions of the frame, before [rotation].
  Rect get region =>
      Rect.fromCenter(center: center, width: size.width, height: size.height);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ObjectTrackSample &&
          other.time == time &&
          other.center == center &&
          other.size == size &&
          other.scale == scale &&
          other.rotation == rotation;

  @override
  int get hashCode => Object.hash(time, center, size, scale, rotation);

  @override
  String toString() =>
      'ObjectTrackSample(time: $time, center: $center, size: $size, '
      'scale: $scale, rotation: $rotation)';
}

/// The path an object takes through a video, found by `VideoObjectTracker`.
///
/// Holds one [ObjectTrackSample] for every frame the object was found in,
/// sorted by source time, starting from the frame it was marked on and
/// reaching as far as it could be followed in both directions. A frame the
/// tracker could not read (motion blur, a hand passing in front) is left out
/// and the object is found again in the next one, so the samples may skip a
/// frame here and there.
@immutable
class VideoObjectTrack {
  /// Creates a [VideoObjectTrack].
  const VideoObjectTrack({
    required this.samples,
    required this.anchorTime,
    this.reachedStart = true,
    this.reachedEnd = true,
  });

  /// Creates a [VideoObjectTrack] from a map written by [toMap].
  factory VideoObjectTrack.fromMap(Map<String, dynamic> map) {
    final times = (map['timesUs'] as List?) ?? const [];
    final values = (map['values'] as List?) ?? const [];
    return VideoObjectTrack(
      anchorTime: Duration(microseconds: safeParseInt(map['anchorTimeUs'])),
      reachedStart: map['reachedStart'] as bool? ?? true,
      reachedEnd: map['reachedEnd'] as bool? ?? true,
      samples: [
        for (var i = 0; i < times.length && 6 * i + 5 < values.length; i++)
          ObjectTrackSample(
            time: Duration(microseconds: safeParseInt(times[i])),
            center: Offset(
              safeParseDouble(values[6 * i]),
              safeParseDouble(values[6 * i + 1]),
            ),
            size: Size(
              safeParseDouble(values[6 * i + 2]),
              safeParseDouble(values[6 * i + 3]),
            ),
            scale: safeParseDouble(values[6 * i + 4], fallback: 1),
            rotation: safeParseDouble(values[6 * i + 5]),
          ),
      ],
    );
  }

  /// One sample per frame the object was found in, sorted by source time.
  final List<ObjectTrackSample> samples;

  /// The source timestamp of the frame the object was marked on, where its
  /// sample has a [ObjectTrackSample.scale] of 1 and no rotation.
  final Duration anchorTime;

  /// Whether the object was followed back to the start of the range. False
  /// when it was lost on the way, e.g. because it came into view later.
  final bool reachedStart;

  /// Whether the object was followed on to the end of the range. False when
  /// it was lost on the way, e.g. because it left the frame.
  final bool reachedEnd;

  /// Whether the object was found in any frame but the one it was marked
  /// on. False when the marked region had too little detail to follow.
  bool get isFollowed => samples.length > 1;

  /// The sample of the frame the object was marked on, or null when there
  /// are no samples.
  ObjectTrackSample? get anchor {
    for (final sample in samples) {
      if (sample.time == anchorTime) return sample;
    }
    return null;
  }

  /// A copy whose path is smoothed with a Gaussian of [position] (the
  /// standard deviation, in source time) for the center and of [shape] for
  /// the size, scale and rotation, which jitter more frame to frame.
  ///
  /// Each value is replaced by a line fitted through its neighbours, weighted
  /// by that Gaussian, rather than by their mean: the path neither lags
  /// behind the object nor is pulled inwards at the ends of the track, where
  /// a mean only sees one side. The marked frame keeps a scale of 1 and no
  /// rotation. A zero duration leaves that part as it is.
  VideoObjectTrack smoothed({
    Duration position = const Duration(milliseconds: 50),
    Duration? shape,
  }) {
    final shapeSigma = shape ?? position * 3;
    if (samples.length < 3 ||
        (position <= Duration.zero && shapeSigma <= Duration.zero)) {
      return this;
    }
    final times = [for (final s in samples) s.time.inMicroseconds.toDouble()];
    List<double> smooth(List<double> values, Duration sigma) {
      if (sigma <= Duration.zero) return values;
      final s = sigma.inMicroseconds.toDouble();
      final reach = 3 * s;
      final out = List<double>.filled(values.length, 0);
      var from = 0;
      for (var i = 0; i < values.length; i++) {
        while (times[from] < times[i] - reach) {
          from++;
        }
        // Weighted least squares of `value = a + b * d` around this time;
        // `a` is the fitted value here.
        var sw = 0.0, swd = 0.0, swdd = 0.0, swv = 0.0, swdv = 0.0;
        for (var j = from; j < values.length; j++) {
          final d = times[j] - times[i];
          if (d > reach) break;
          final w = math.exp(-0.5 * d * d / (s * s));
          final ds = d / s;
          sw += w;
          swd += w * ds;
          swdd += w * ds * ds;
          swv += w * values[j];
          swdv += w * ds * values[j];
        }
        final det = sw * swdd - swd * swd;
        out[i] = det.abs() < 1e-9 * sw * sw
            ? swv / sw
            : (swdd * swv - swd * swdv) / det;
      }
      return out;
    }

    final cx = smooth([for (final s in samples) s.center.dx], position);
    final cy = smooth([for (final s in samples) s.center.dy], position);
    final logScale = smooth([
      for (final s in samples) math.log(s.scale),
    ], shapeSigma);
    final rotation = smooth([for (final s in samples) s.rotation], shapeSigma);
    final anchorIndex = samples.indexWhere((s) => s.time == anchorTime);
    final logScaleAtAnchor = anchorIndex < 0 ? 0.0 : logScale[anchorIndex];
    final rotationAtAnchor = anchorIndex < 0 ? 0.0 : rotation[anchorIndex];
    return VideoObjectTrack(
      anchorTime: anchorTime,
      reachedStart: reachedStart,
      reachedEnd: reachedEnd,
      samples: [
        for (var i = 0; i < samples.length; i++)
          () {
            final scale = math.exp(logScale[i] - logScaleAtAnchor);
            // The size follows the smoothed scale, so the two stay in step.
            final ratio = scale / samples[i].scale;
            return ObjectTrackSample(
              time: samples[i].time,
              center: Offset(cx[i], cy[i]),
              size: samples[i].size * ratio,
              scale: scale,
              rotation: rotation[i] - rotationAtAnchor,
            );
          }(),
      ],
    );
  }

  /// Serializes this object. Samples are packed into flat lists: `timesUs`,
  /// and six `values` per sample (center x, center y, width, height, scale,
  /// rotation).
  Map<String, dynamic> toMap() => <String, dynamic>{
    'anchorTimeUs': anchorTime.inMicroseconds,
    'reachedStart': reachedStart,
    'reachedEnd': reachedEnd,
    'timesUs': [for (final s in samples) s.time.inMicroseconds],
    'values': [
      for (final s in samples) ...[
        s.center.dx,
        s.center.dy,
        s.size.width,
        s.size.height,
        s.scale,
        s.rotation,
      ],
    ],
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoObjectTrack &&
          other.anchorTime == anchorTime &&
          other.reachedStart == reachedStart &&
          other.reachedEnd == reachedEnd &&
          listEquals(other.samples, samples);

  @override
  int get hashCode => Object.hash(
    anchorTime,
    reachedStart,
    reachedEnd,
    Object.hashAll(samples),
  );

  @override
  String toString() =>
      'VideoObjectTrack(${samples.length} samples, anchorTime: $anchorTime, '
      'reachedStart: $reachedStart, reachedEnd: $reachedEnd)';
}
