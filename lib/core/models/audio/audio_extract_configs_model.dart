import '/core/models/video/editor_video_model.dart';
import 'audio_format_model.dart';

/// Configuration for extracting audio from a video.
///
/// This model contains all necessary parameters for audio extraction:
/// - Video source
/// - Output audio format
/// - Quality settings (bitrate)
/// - Optional trimming (start/end time)
/// - Task ID for progress tracking
class AudioExtractConfigs {
  /// Creates an [AudioExtractConfigs] instance with the given parameters.
  ///
  /// [video] The source video to extract audio from.
  /// [format] The desired output audio format (default: [AudioFormat.mp3]).
  /// [startTime] Optional start time for trimming. If null, starts from
  /// beginning.
  /// [endTime] Optional end time for trimming. If null, goes to video end.
  /// [speed] Playback speed multiplier for the extracted audio (default `1.0`).
  /// [id] Unique task identifier. Generated automatically if not provided.
  AudioExtractConfigs({
    required this.video,
    this.format = AudioFormat.mp3,
    this.startTime,
    this.endTime,
    this.speed = 1.0,
    String? id,
  }) : assert(speed > 0, '[speed] must be greater than 0'),
       id = id ?? DateTime.now().millisecondsSinceEpoch.toString();

  /// The source video to extract audio from.
  final EditorVideo video;

  /// The output audio format.
  final AudioFormat format;

  /// Optional start time for trimming the audio.
  ///
  /// If provided, audio extraction will begin at this timestamp.
  /// If null, extraction starts from the beginning of the video.
  final Duration? startTime;

  /// Optional end time for trimming the audio.
  ///
  /// If provided, audio extraction will end at this timestamp.
  /// If null, extraction continues to the end of the video.
  final Duration? endTime;

  /// Playback speed multiplier applied to the extracted audio.
  ///
  /// For example, `0.5` for half speed, `2.0` for double speed.
  /// The pitch is preserved (time-stretch), matching the editor's video
  /// rendering behavior.
  ///
  /// **Default**: `1.0` (original speed)
  final double speed;

  /// Unique identifier for tracking progress of this extraction task.
  ///
  /// Used with [ProVideoEditor.progressStreamById] to monitor extraction
  /// progress.
  final String id;

  /// Converts this configuration to a map for platform channel communication.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'format': format.name,
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
      'speed': speed,
    };
  }

  /// Creates a copy of this config with optional parameter overrides.
  AudioExtractConfigs copyWith({
    EditorVideo? video,
    AudioFormat? format,
    Duration? startTime,
    Duration? endTime,
    double? speed,
    String? id,
  }) {
    return AudioExtractConfigs(
      video: video ?? this.video,
      format: format ?? this.format,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      speed: speed ?? this.speed,
      id: id ?? this.id,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is AudioExtractConfigs &&
        other.video == video &&
        other.format == format &&
        other.startTime == startTime &&
        other.endTime == endTime &&
        other.speed == speed &&
        other.id == id;
  }

  @override
  int get hashCode {
    return video.hashCode ^
        format.hashCode ^
        startTime.hashCode ^
        endTime.hashCode ^
        speed.hashCode ^
        id.hashCode;
  }

  @override
  String toString() {
    return 'AudioExtractConfigs(video: $video, format: $format, '
        'startTime: $startTime, endTime: $endTime, speed: $speed, id: $id)';
  }
}
