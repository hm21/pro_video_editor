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
  final double? playbackSpeed;

  /// Whether to render this segment backwards.
  ///
  /// When `true`, this segment plays from its trimmed end back to its trimmed
  /// start. Other segments keep their own order and direction.
  ///
  /// **Default**: `false`
  final bool reverseVideo;

  /// The transition played between this clip and the **next** clip.
  ///
  /// Describes how this segment transitions into the following segment (e.g. a
  /// dissolve or fade-to-black). The transition is ignored on the last segment
  /// because there is no following clip.
  ///
  /// Currently supported on Android and iOS/macOS only; other platforms
  /// ignore this field.
  final ClipTransition? transition;

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
  }) {
    return VideoSegment(
      video: video ?? this.video,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      volume: volume ?? this.volume,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      reverseVideo: reverseVideo ?? this.reverseVideo,
      transition: transition ?? this.transition,
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
        other.transition == transition;
  }

  @override
  int get hashCode {
    return video.hashCode ^
        startTime.hashCode ^
        endTime.hashCode ^
        volume.hashCode ^
        playbackSpeed.hashCode ^
        reverseVideo.hashCode ^
        transition.hashCode;
  }

  @override
  String toString() {
    return 'VideoSegment(video: $video, '
        'startTime: $startTime, '
        'endTime: $endTime, '
        'volume: $volume, '
        'playbackSpeed: $playbackSpeed, '
        'reverseVideo: $reverseVideo, '
        'transition: $transition)';
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
    );
  }

  String toJson() => json.encode(toMap());

  factory VideoSegment.fromJson(String source) =>
      VideoSegment.fromMap(json.decode(source) as Map<String, dynamic>);
}
