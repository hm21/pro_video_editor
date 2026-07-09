// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';

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
    this.playbackSpeed,
    this.reverseVideo = false,
    this.transition,
    this.timelineStart,
    this.transform,
  }) : assert(
         startTime == null || endTime == null || startTime < endTime,
         'startTime must be before endTime',
       ),
       assert(
         volume == null || volume >= 0,
         '[volume] must be greater than or equal to 0',
       ),
       assert(
         playbackSpeed == null || playbackSpeed > 0,
         '[playbackSpeed] must be greater than 0',
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

  /// Playback speed of this segment.
  ///
  /// For example, `0.5` for half speed, `2.0` for double speed.
  ///
  /// If null, the original speed is used.
  ///
  /// **Not supported inside a [VideoComposition]:** per-clip playback speed is
  /// ignored for composition clips. Pre-render the speed change into the source
  /// or use [videoSegments] instead.
  final double? playbackSpeed;

  /// Whether to render this segment backwards.
  ///
  /// When `true`, this segment plays from its trimmed end back to its trimmed
  /// start. Other segments keep their own order and direction.
  ///
  /// **Default**: `false`
  ///
  /// **Not supported inside a [VideoComposition]:** reverse playback is ignored
  /// for composition clips. Pre-render the reversed source or use
  /// [videoSegments] instead.
  final bool reverseVideo;

  /// The transition played between this clip and the **next** clip.
  ///
  /// Describes how this segment transitions into the following segment (e.g. a
  /// dissolve or fade-to-black).
  ///
  /// **On the last (or only) segment** there is no following clip, so the
  /// transition instead **wraps back into the first segment**, turning the
  /// whole track into a seamless loop: the end dissolves (or dips) into the
  /// beginning, so a looping player restarts without a visible cut. For overlap
  /// transitions (dissolve/slide/push/wipe) the output is shortened by the
  /// transition duration — exactly like an overlap transition between two clips
  /// — and for a single segment the clip must be longer than twice the
  /// transition duration (otherwise the wrap is skipped and the loop restarts
  /// hard). Dip transitions (fadeToBlack/fadeToWhite) keep the duration and dip
  /// through the color at the restart seam.
  ///
  /// Currently supported on Android and iOS/macOS only; other platforms
  /// ignore this field.
  ///
  /// **Not supported inside a [VideoComposition]:** transitions are ignored for
  /// composition clips. Use [videoSegments] when you need clip transitions.
  final ClipTransition? transition;

  /// Start position of this clip on its layer's timeline.
  ///
  /// Only used when the segment is part of a [VideoComposition]. It defines
  /// when the clip begins relative to the start of the composition. Any gap
  /// before it is filled with the composition's background.
  ///
  /// When `null`, the clip starts right after the previous clip on the same
  /// layer (back-to-back concatenation).
  final Duration? timelineStart;

  /// Position and scale of this clip within the composition canvas.
  ///
  /// Only used when the segment is part of a [VideoComposition]. Overrides the
  /// [VideoLayer.transform]. When `null`, the clip uses its layer's transform,
  /// or fills the entire canvas if neither is set.
  final SegmentTransform? transform;

  /// Converts this clip to a map for platform channel communication.
  Future<Map<String, dynamic>> toAsyncMap() async {
    final inputPath = await video.safeFilePath();

    return {
      'inputPath': inputPath,
      'startUs': startTime?.inMicroseconds,
      'endUs': endTime?.inMicroseconds,
      'volume': volume,
      'playbackSpeed': playbackSpeed,
      'reverseVideo': reverseVideo,
      'transition': transition?.toMap(),
      'timelineStartUs': timelineStart?.inMicroseconds,
      'transform': transform?.toMap(),
    };
  }

  /// Creates a copy with updated values.
  VideoSegment copyWith({
    EditorVideo? video,
    Duration? startTime,
    Duration? endTime,
    double? volume,
    double? playbackSpeed,
    bool? reverseVideo,
    ClipTransition? transition,
    Duration? timelineStart,
    SegmentTransform? transform,
  }) {
    return VideoSegment(
      video: video ?? this.video,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      volume: volume ?? this.volume,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      reverseVideo: reverseVideo ?? this.reverseVideo,
      transition: transition ?? this.transition,
      timelineStart: timelineStart ?? this.timelineStart,
      transform: transform ?? this.transform,
    );
  }

  @override
  bool operator ==(covariant VideoSegment other) {
    if (identical(this, other)) return true;

    return other.video == video &&
        other.startTime == startTime &&
        other.endTime == endTime &&
        other.volume == volume &&
        other.playbackSpeed == playbackSpeed &&
        other.reverseVideo == reverseVideo &&
        other.transition == transition &&
        other.timelineStart == timelineStart &&
        other.transform == transform;
  }

  @override
  int get hashCode {
    return video.hashCode ^
        startTime.hashCode ^
        endTime.hashCode ^
        volume.hashCode ^
        playbackSpeed.hashCode ^
        reverseVideo.hashCode ^
        transition.hashCode ^
        timelineStart.hashCode ^
        transform.hashCode;
  }

  @override
  String toString() {
    return 'VideoSegment(video: $video, '
        'startTime: $startTime, '
        'endTime: $endTime, '
        'volume: $volume, '
        'playbackSpeed: $playbackSpeed, '
        'reverseVideo: $reverseVideo, '
        'transition: $transition, '
        'timelineStart: $timelineStart, '
        'transform: $transform)';
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'video': video.toMap(),
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
      'volume': volume,
      'playbackSpeed': playbackSpeed,
      'reverseVideo': reverseVideo,
      'transition': transition?.toMap(),
      'timelineStart': timelineStart?.inMicroseconds,
      'transform': transform?.toMap(),
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
      playbackSpeed: tryParseDouble(map['playbackSpeed']),
      reverseVideo: map['reverseVideo'] as bool? ?? false,
      transition: map['transition'] != null
          ? ClipTransition.fromMap(map['transition'] as Map<String, dynamic>)
          : null,
      timelineStart: map['timelineStart'] != null
          ? Duration(microseconds: safeParseInt(map['timelineStart']))
          : null,
      transform: map['transform'] != null
          ? SegmentTransform.fromMap(map['transform'] as Map<String, dynamic>)
          : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory VideoSegment.fromJson(String source) =>
      VideoSegment.fromMap(json.decode(source) as Map<String, dynamic>);
}
