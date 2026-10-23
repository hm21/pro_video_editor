import '/core/models/video/editor_video_model.dart';
import '/shared/utils/unique_task_id.dart';

/// Resolution presets for waveform generation.
///
/// Higher resolutions provide more detail but require more memory
/// and processing time. Choose based on your use case:
///
/// - [low] - Overview displays, small thumbnails
/// - [medium] - Standard timeline displays
/// - [high] - Detailed editing views
/// - [ultra] - Frame-accurate editing, DAW-style interfaces
enum WaveformResolution {
  /// Low resolution: ~10 samples/second.
  /// Good for overview displays and thumbnails.
  /// Memory: ~400 bytes per minute of audio.
  low(10),

  /// Medium resolution: ~50 samples/second.
  /// Good for standard timeline displays.
  /// Memory: ~2KB per minute of audio.
  medium(50),

  /// High resolution: ~200 samples/second.
  /// Good for detailed editing views.
  /// Memory: ~8KB per minute of audio.
  high(200),

  /// Ultra resolution: ~500 samples/second.
  /// Good for frame-accurate editing at 30fps.
  /// Memory: ~20KB per minute of audio.
  ultra(500);

  const WaveformResolution(this.samplesPerSecond);

  /// Number of waveform samples generated per second of audio.
  final int samplesPerSecond;
}

/// Configuration for waveform generation.
///
/// Specifies the audio source, desired resolution, and optional
/// time range for partial waveform generation.
///
/// For streaming waveform generation, use [chunkSize] to control how many
/// samples are emitted per chunk.
///
/// Example (non-streaming):
/// ```dart
/// final configs = WaveformConfigs(
///   video: EditorVideo.file('/path/to/video.mp4'),
///   resolution: WaveformResolution.high,
///   startTime: Duration(seconds: 10),
///   endTime: Duration(seconds: 60),
/// );
///
/// final waveform = await ProVideoEditor.instance.getWaveform(configs);
/// ```
///
/// Example (streaming):
/// ```dart
/// final configs = WaveformConfigs(
///   video: EditorVideo.file('/path/to/video.mp4'),
///   resolution: WaveformResolution.high,
///   chunkSize: 100, // Emit every 100 samples
/// );
///
/// await for (final chunk in
/// ProVideoEditor.instance.getWaveformStream(configs)) {
///   // Process chunk progressively
///   updateWaveformDisplay(chunk);
/// }
/// ```
class WaveformConfigs {
  /// Creates a [WaveformConfigs] instance.
  ///
  /// [video] The source video to extract audio waveform from.
  /// [resolution] Desired waveform resolution (default: medium).
  /// [startTime] Optional start time for partial extraction.
  /// [endTime] Optional end time for partial extraction.
  /// [id] Unique task identifier for progress tracking.
  /// [chunkSize] Number of samples per chunk for streaming mode (default: 100).
  WaveformConfigs({
    required this.video,
    this.resolution = WaveformResolution.medium,
    this.startTime,
    this.endTime,
    this.chunkSize = 100,
    String? id,
  }) : id = id ?? uniqueTaskId();

  /// The source video to extract audio waveform from.
  final EditorVideo video;

  /// Desired waveform resolution.
  ///
  /// Higher resolutions provide more detail but increase processing
  /// time and memory usage.
  final WaveformResolution resolution;

  /// Optional start time for partial waveform extraction.
  ///
  /// If null, extraction starts from the beginning.
  final Duration? startTime;

  /// Optional end time for partial waveform extraction.
  ///
  /// If null, extraction continues to the end.
  final Duration? endTime;

  /// Unique identifier for tracking progress of this task.
  ///
  /// Used with [ProVideoEditor.progressStreamById] to monitor
  /// waveform generation progress.
  final String id;

  /// Number of samples per chunk for streaming mode.
  ///
  /// When using [ProVideoEditor.getWaveformStream], this determines how
  /// many waveform samples are included in each emitted [WaveformChunk].
  ///
  /// Smaller values provide more frequent updates but increase overhead.
  /// Larger values are more efficient but delay the first visual feedback.
  ///
  /// Default: 100 samples per chunk.
  final int chunkSize;

  /// Converts this configuration to a map for platform channel communication.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'samplesPerSecond': resolution.samplesPerSecond,
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
      'chunkSize': chunkSize,
    };
  }

  /// Creates a copy with optional parameter overrides.
  WaveformConfigs copyWith({
    EditorVideo? video,
    WaveformResolution? resolution,
    Duration? startTime,
    Duration? endTime,
    String? id,
    int? chunkSize,
  }) {
    return WaveformConfigs(
      video: video ?? this.video,
      resolution: resolution ?? this.resolution,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      id: id ?? this.id,
      chunkSize: chunkSize ?? this.chunkSize,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WaveformConfigs &&
        other.video == video &&
        other.resolution == resolution &&
        other.startTime == startTime &&
        other.endTime == endTime &&
        other.id == id &&
        other.chunkSize == chunkSize;
  }

  @override
  int get hashCode {
    return video.hashCode ^
        resolution.hashCode ^
        startTime.hashCode ^
        endTime.hashCode ^
        id.hashCode ^
        chunkSize.hashCode;
  }
}
