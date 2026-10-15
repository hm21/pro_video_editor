import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

/// How one source frame is moved to steady the shot.
///
/// The frame is scaled by [scale] and turned by [rotation] around its center,
/// then shifted by [offset]. Everything is in the frame's own upright pixel
/// space with the origin top left, the way the video is displayed.
@immutable
class StabilizationKeyframe {
  /// Creates a [StabilizationKeyframe].
  const StabilizationKeyframe({
    required this.time,
    this.offset = Offset.zero,
    this.rotation = 0,
    this.scale = 1,
  }) : assert(scale > 0, '[scale] must be positive');

  /// The source timestamp of the frame this applies to: the position in the
  /// video file, not on the rendered timeline.
  final Duration time;

  /// The shift, as a fraction of the frame's width (dx) and height (dy). A
  /// positive dx moves the picture right, a positive dy moves it down.
  final Offset offset;

  /// The rotation in radians, clockwise on screen.
  final double rotation;

  /// The scale around the frame's center, including the zoom that keeps the
  /// borders out of view.
  final double scale;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StabilizationKeyframe &&
          other.time == time &&
          other.offset == offset &&
          other.rotation == rotation &&
          other.scale == scale;

  @override
  int get hashCode => Object.hash(time, offset, rotation, scale);

  @override
  String toString() =>
      'StabilizationKeyframe(time: $time, offset: $offset, '
      'rotation: $rotation, scale: $scale)';
}

/// A per-frame transform that steadies a shaky video.
///
/// Produced by `VideoStabilizationAnalyzer` from the video's frames and
/// applied through `VideoSegment.stabilization`: each source frame takes the
/// keyframe of its own timestamp, frames the analysis skipped are
/// interpolated, and the first and last keyframe hold outside their range.
///
/// Every pixel of the result is a pixel of the source: the borders the
/// movement would expose are hidden by zooming in, never filled.
@immutable
class VideoStabilization {
  /// Creates a [VideoStabilization].
  const VideoStabilization({
    required this.keyframes,
    required this.zoom,
    this.unreliableFrames = 0,
    this.attenuatedFrames = 0,
  });

  /// Creates a [VideoStabilization] from a map written by [toMap].
  factory VideoStabilization.fromMap(Map<String, dynamic> map) {
    final times = (map['timesUs'] as List?) ?? const [];
    final values = (map['values'] as List?) ?? const [];
    return VideoStabilization(
      zoom: safeParseDouble(map['zoom'], fallback: 1),
      unreliableFrames: safeParseInt(map['unreliableFrames']),
      attenuatedFrames: safeParseInt(map['attenuatedFrames']),
      keyframes: [
        for (var i = 0; i < times.length && 4 * i + 3 < values.length; i++)
          StabilizationKeyframe(
            time: Duration(microseconds: safeParseInt(times[i])),
            offset: Offset(
              safeParseDouble(values[4 * i]),
              safeParseDouble(values[4 * i + 1]),
            ),
            rotation: safeParseDouble(values[4 * i + 2]),
            scale: safeParseDouble(values[4 * i + 3], fallback: 1),
          ),
      ],
    );
  }

  /// One transform per analyzed frame, sorted by source time.
  final List<StabilizationKeyframe> keyframes;

  /// The zoom included in every keyframe's scale, at least 1.
  final double zoom;

  /// Frame pairs whose motion could not be measured (motion blur, a flat
  /// wall, a cut) and was interpolated from their neighbours.
  final int unreliableFrames;

  /// Frames whose correction was reduced to stay within the zoom limit, and
  /// which keep some of their shake.
  final int attenuatedFrames;

  /// Serializes this object. Keyframes are packed into flat lists:
  /// `timesUs`, and four `values` per keyframe (dx, dy, rotation, scale).
  Map<String, dynamic> toMap() => <String, dynamic>{
    'zoom': zoom,
    'unreliableFrames': unreliableFrames,
    'attenuatedFrames': attenuatedFrames,
    'timesUs': [for (final k in keyframes) k.time.inMicroseconds],
    'values': [
      for (final k in keyframes) ...[
        k.offset.dx,
        k.offset.dy,
        k.rotation,
        k.scale,
      ],
    ],
  };

  @override
  String toString() =>
      'VideoStabilization(${keyframes.length} keyframes, '
      'zoom: ${zoom.toStringAsFixed(3)})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoStabilization &&
          other.zoom == zoom &&
          other.unreliableFrames == unreliableFrames &&
          other.attenuatedFrames == attenuatedFrames &&
          listEquals(other.keyframes, keyframes);

  @override
  int get hashCode => Object.hash(
    zoom,
    unreliableFrames,
    attenuatedFrames,
    Object.hashAll(keyframes),
  );
}
