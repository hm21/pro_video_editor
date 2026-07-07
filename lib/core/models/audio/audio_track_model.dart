// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';

import 'package:pro_video_editor/shared/models/time_range_mixin.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

/// A model representing an audio track with timing information.
///
/// Each [VideoAudioTrack] references a custom audio file that can be mixed into
/// the video during a specific time range.
///
/// If [startTime] and [endTime] are both `null`, the audio plays for the
/// entire duration of the video.
class VideoAudioTrack with TimeRangeMixin {
  /// Creates an [VideoAudioTrack] with the given [path], [startTime],
  /// and optional [endTime].
  const VideoAudioTrack({
    required this.path,
    this.volume = 1.0,
    this.loop = false,
    this.audioStartTime,
    this.audioEndTime,
    this.startTime,
    this.endTime,
  }) : assert(volume >= 0, '[volume] must be greater than or equal to 0'),
       assert(
         startTime == null || endTime == null || startTime < endTime,
         'startTime must be before endTime',
       );

  /// Path to the audio file.
  final String path;

  /// Volume multiplier for this audio track.
  ///
  /// - `0.0`: Mute
  /// - `1.0`: Full volume (default)
  /// - `> 1.0`: Amplified
  final double volume;

  /// Whether to loop the audio if it is shorter than the time range.
  ///
  /// **Default**: `false`
  final bool loop;

  /// The start time offset within the audio file.
  ///
  /// When provided, playback begins from this position in the audio file
  /// instead of from the beginning.
  final Duration? audioStartTime;

  /// The end time offset within the audio file.
  ///
  /// When provided, playback stops at this position in the audio file
  /// instead of at the end.
  final Duration? audioEndTime;

  @override
  final Duration? startTime;

  @override
  final Duration? endTime;

  VideoAudioTrack copyWith({
    String? path,
    double? volume,
    bool? loop,
    Duration? audioStartTime,
    Duration? audioEndTime,
    Duration? startTime,
    Duration? endTime,
  }) {
    return VideoAudioTrack(
      path: path ?? this.path,
      volume: volume ?? this.volume,
      loop: loop ?? this.loop,
      audioStartTime: audioStartTime ?? this.audioStartTime,
      audioEndTime: audioEndTime ?? this.audioEndTime,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'path': path,
      'volume': volume,
      'loop': loop,
      'audioStartTime': audioStartTime?.inMicroseconds,
      'audioEndTime': audioEndTime?.inMicroseconds,
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
    };
  }

  factory VideoAudioTrack.fromMap(Map<String, dynamic> map) {
    return VideoAudioTrack(
      path: map['path'] as String,
      volume: safeParseDouble(map['volume'], fallback: 1.0),
      loop: map['loop'] as bool,
      audioStartTime: map['audioStartTime'] != null
          ? Duration(microseconds: safeParseInt(map['audioStartTime']))
          : null,
      audioEndTime: map['audioEndTime'] != null
          ? Duration(microseconds: safeParseInt(map['audioEndTime']))
          : null,
      startTime: map['startTime'] != null
          ? Duration(microseconds: safeParseInt(map['startTime']))
          : null,
      endTime: map['endTime'] != null
          ? Duration(microseconds: safeParseInt(map['endTime']))
          : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory VideoAudioTrack.fromJson(String source) =>
      VideoAudioTrack.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() {
    return 'VideoAudioTrack(path: $path, volume: $volume, loop: $loop, '
        'audioStartTime: $audioStartTime, audioEndTime: $audioEndTime, '
        'startTime: $startTime, endTime: $endTime)';
  }

  @override
  bool operator ==(covariant VideoAudioTrack other) {
    if (identical(this, other)) return true;

    return other.path == path &&
        other.volume == volume &&
        other.loop == loop &&
        other.audioStartTime == audioStartTime &&
        other.audioEndTime == audioEndTime &&
        other.startTime == startTime &&
        other.endTime == endTime;
  }

  @override
  int get hashCode {
    return path.hashCode ^
        volume.hashCode ^
        loop.hashCode ^
        audioStartTime.hashCode ^
        audioEndTime.hashCode ^
        startTime.hashCode ^
        endTime.hashCode;
  }
}
