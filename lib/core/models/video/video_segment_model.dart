// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';
import 'dart:ui';

import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

/// Represents a single video clip to be included in a video composition.
///
/// Each clip can have its own start and end time for trimming.
/// Multiple clips can be combined to create a concatenated video.
class VideoSegment {
  /// Creates a [VideoSegment] with the given parameters.
  const VideoSegment({
    required this.video,
    this.startTime,
    this.endTime,
    this.volume,
    this.offset,
    this.size,
    this.zIndex,
    this.opacity,
    this.segmentTime,
  })  : assert(
          startTime == null || endTime == null || startTime < endTime,
          'startTime must be before endTime',
        ),
        assert(
          volume == null || volume >= 0,
          '[volume] must be greater than or equal to 0',
        );

  /// The video source for this clip.
  ///
  /// This class supports videos from in-memory bytes, file system, network,
  /// or asset bundle.
  final EditorVideo video;

  /// Optional start time for trimming this clip.
  ///
  /// If null, the clip starts from the beginning of the video.
  final Duration? startTime;

  /// Optional end time for trimming this clip.
  ///
  /// If null, the clip plays until the end of the video.
  final Duration? endTime;

  /// Volume multiplier for this segment's audio.
  ///
  /// - `0.0`: Mute
  /// - `1.0`: Original volume
  /// - `> 1.0`: Amplified
  ///
  /// If null, the original volume is used.
  final double? volume;

  /// The stacking order of overlapping elements along the z-axis.
  /// Segments with higher zIndex are rendered on top.
  /// Defaulted to 0 if not specified.
  ///
  /// If multiple segments have the same zIndex, then their order is used
  /// (the latter segment is higher)
  ///
  final int? zIndex;

  /// The opacity of of this video segments used with overlapping elements
  final double? opacity;

  /// Position offset from the top-left corner of the video frame, in pixels.
  ///
  /// [Offset.dx] is the horizontal offset from the left edge.
  /// [Offset.dy] is the vertical offset from the top edge.
  ///
  /// When `null`, the image is stretched to fill the entire video frame.
  /// When set to a specific value (e.g., [Offset.zero]), the image is
  /// placed at that position at its original size.
  final Offset? offset;

  /// The display size of the image layer, in pixels.
  ///
  /// [Size.width] is the target width of the image.
  /// [Size.height] is the target height of the image.
  ///
  /// When `null`, the image is used at its original size (or stretched to
  /// fill the frame when [offset] is also `null`).
  final Size? size;

  /// Optional start time for this video segment in the rendered video
  ///
  /// If null, the clip will start right after the previous video segment
  final Duration? segmentTime;

  /// Converts this clip to a map for platform channel communication.
  Future<Map<String, dynamic>> toAsyncMap() async {
    final inputPath = await video.safeFilePath();

    return {
      'inputPath': inputPath,
      'startUs': startTime?.inMicroseconds,
      'endUs': endTime?.inMicroseconds,
      'volume': volume,
      'zIndex': zIndex,
      'opacity': opacity,
      'x': offset?.dx,
      'y': offset?.dy,
      'width': size?.width,
      'height': size?.height,
      'segmentTimeUs': segmentTime?.inMicroseconds,
    };
  }

  /// Creates a copy with updated values.
  VideoSegment copyWith({
    EditorVideo? video,
    Duration? startTime,
    Duration? endTime,
    double? volume,
    double? opacity,
    int? zIndex,
    Offset? offset,
    Size? size,
    Duration? segmentTime,
  }) {
    return VideoSegment(
      video: video ?? this.video,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      volume: volume ?? this.volume,
      zIndex: zIndex ?? this.zIndex,
      opacity: opacity ?? this.opacity,
      offset: offset ?? this.offset,
      size: size ?? this.size,
      segmentTime: segmentTime ?? this.segmentTime,
    );
  }

  @override
  bool operator ==(covariant VideoSegment other) {
    if (identical(this, other)) return true;

    return other.video == video &&
        other.startTime == startTime &&
        other.endTime == endTime &&
        other.volume == volume &&
        other.zIndex == zIndex &&
        other.opacity == opacity &&
        other.offset == offset &&
        other.size == size &&
        other.segmentTime == segmentTime;
  }

  @override
  int get hashCode {
    return video.hashCode ^
        startTime.hashCode ^
        endTime.hashCode ^
        volume.hashCode ^
        zIndex.hashCode ^
        opacity.hashCode ^
        offset.hashCode ^
        size.hashCode ^
        segmentTime.hashCode;
  }

  @override
  String toString() {
    return 'VideoSegment(video: $video, '
        'startTime: $startTime, '
        'endTime: $endTime, '
        'volume: $volume, '
        'zIndex: $zIndex, '
        'opacity: $opacity, '
        'offset: $offset, '
        'size: $size, '
        'segmentTime: $segmentTime)';
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'video': video.toMap(),
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
      'volume': volume,
      'zIndex': zIndex,
      'opacity': opacity,
      'offset': offset != null ? {'dx': offset!.dx, 'dy': offset!.dy} : null,
      'size':
          size != null ? {'width': size!.width, 'height': size!.height} : null,
      'segmentTime': segmentTime?.inMicroseconds,
    };
  }

  factory VideoSegment.fromMap(Map<String, dynamic> map) {
    return VideoSegment(
      video: EditorVideo.fromMap(map['video'] as Map<String, dynamic>),
      startTime: map['startTime'] != null
          ? Duration(microseconds: safeParseInt(map['startTime']))
          : null,
      endTime: map['endTime'] != null
          ? Duration(microseconds: safeParseInt(map['endTime']))
          : null,
      volume: tryParseDouble(map['volume']),
      zIndex: tryParseInt(map['zIndex']),
      opacity: tryParseDouble(map['opacity']),
      offset: map['offset'] != null
          ? Offset(
              safeParseDouble((map['offset'] as Map<String, dynamic>)['dx']),
              safeParseDouble((map['offset'] as Map<String, dynamic>)['dy']),
            )
          : null,
      size: map['size'] != null
          ? Size(
              safeParseDouble((map['size'] as Map<String, dynamic>)['width']),
              safeParseDouble((map['size'] as Map<String, dynamic>)['height']),
            )
          : null,
      segmentTime: map['segmentTime'] != null
          ? Duration(microseconds: safeParseInt(map['segmentTime']))
          : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory VideoSegment.fromJson(String source) =>
      VideoSegment.fromMap(json.decode(source) as Map<String, dynamic>);
}
