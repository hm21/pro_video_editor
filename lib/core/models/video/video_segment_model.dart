import 'package:pro_video_editor/pro_video_editor.dart';

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

  /// Converts this clip to a map for platform channel communication.
  Future<Map<String, dynamic>> toAsyncMap() async {
    final inputPath = await video.safeFilePath();

    return {
      'inputPath': inputPath,
      'startUs': startTime?.inMicroseconds,
      'endUs': endTime?.inMicroseconds,
      'volume': volume,
    };
  }

  /// Creates a copy with updated values.
  VideoSegment copyWith({
    EditorVideo? video,
    Duration? startTime,
    Duration? endTime,
    double? volume,
  }) {
    return VideoSegment(
      video: video ?? this.video,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      volume: volume ?? this.volume,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is VideoSegment &&
        other.video == video &&
        other.startTime == startTime &&
        other.endTime == endTime &&
        other.volume == volume;
  }

  @override
  int get hashCode => Object.hash(video, startTime, endTime, volume);

  @override
  String toString() {
    return 'VideoSegment('
        'video: $video, '
        'startTime: $startTime, '
        'endTime: $endTime, '
        'volume: $volume)';
  }
}
