import 'package:pro_video_editor/shared/models/time_range_mixin.dart';

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
    this.startTime,
    this.endTime,
    this.volume = 1.0,
    this.loop = false,
    this.audioStartTime,
    this.audioEndTime,
  })  : assert(
          volume >= 0,
          '[volume] must be greater than or equal to 0',
        ),
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
}
