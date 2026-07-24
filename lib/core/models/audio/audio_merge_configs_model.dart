import '/core/models/video/editor_video_model.dart';
import 'audio_format_model.dart';

/// A single trimmed audio window that participates in an audio merge.
///
/// Each segment references a source [video] and the `[startTime, endTime)`
/// window (measured in the **source** timeline) whose audio should be taken.
/// After trimming, [speed] is applied as a time-stretch (pitch preserved,
/// matching the editor's rendering behavior).
///
/// The segment's contribution to the merged output is exactly
/// `(endTime - startTime) / speed`, regardless of whether the source actually
/// has an audio track — a source without audio contributes silence of that
/// same length (see [AudioMergeConfigs]).
class AudioMergeSegment {
  /// Creates an [AudioMergeSegment].
  ///
  /// [video] The source video/audio to take the window from.
  /// [startTime] Window start, a position in the **source** timeline.
  /// [endTime] Window end, a position in the **source** timeline. Must be
  /// strictly greater than [startTime].
  /// [speed] Playback speed multiplier applied after trimming (default `1.0`).
  /// Must be greater than `0`.
  AudioMergeSegment({
    required this.video,
    required this.startTime,
    required this.endTime,
    this.speed = 1.0,
  }) : assert(speed > 0, '[speed] must be greater than 0'),
       assert(endTime > startTime, '[endTime] must be after [startTime]');

  /// The source video to take the audio window from.
  final EditorVideo video;

  /// Window start — a position in the **source** timeline.
  final Duration startTime;

  /// Window end — a position in the **source** timeline, `> startTime`.
  final Duration endTime;

  /// Playback speed multiplier applied to the trimmed window.
  ///
  /// For example `0.5` for half speed, `2.0` for double speed. The pitch is
  /// preserved (time-stretch), matching the editor's video rendering behavior.
  ///
  /// **Default**: `1.0` (original speed)
  final double speed;

  /// The window length in the source timeline (`endTime - startTime`).
  Duration get trimmedDuration => endTime - startTime;

  /// The segment's contribution to the merged output — `trimmedDuration`
  /// divided by [speed].
  Duration get outputDuration =>
      Duration(microseconds: (trimmedDuration.inMicroseconds / speed).round());

  /// Converts this segment to a map for platform channel communication.
  ///
  /// [inputPath] is the resolved local file path for [video] (produced by
  /// [EditorVideo.safeFilePath]).
  Map<String, dynamic> toMap(String inputPath) {
    return {
      'inputPath': inputPath,
      'startTime': startTime.inMicroseconds,
      'endTime': endTime.inMicroseconds,
      'speed': speed,
    };
  }

  /// Creates a copy of this segment with optional parameter overrides.
  AudioMergeSegment copyWith({
    EditorVideo? video,
    Duration? startTime,
    Duration? endTime,
    double? speed,
  }) {
    return AudioMergeSegment(
      video: video ?? this.video,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      speed: speed ?? this.speed,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is AudioMergeSegment &&
        other.video == video &&
        other.startTime == startTime &&
        other.endTime == endTime &&
        other.speed == speed;
  }

  @override
  int get hashCode {
    return video.hashCode ^
        startTime.hashCode ^
        endTime.hashCode ^
        speed.hashCode;
  }

  @override
  String toString() {
    return 'AudioMergeSegment(video: $video, startTime: $startTime, '
        'endTime: $endTime, speed: $speed)';
  }
}

/// Configuration for merging the audio of several trimmed clip windows into a
/// single, seamlessly concatenated audio file.
///
/// The [segments] are processed **in list order** and concatenated with **no
/// gaps and no silence inserted between them**. Every segment is decoded and
/// re-encoded to a single uniform format (same sample rate, channel count and
/// bit depth) so the concatenation is seamless.
///
/// ### Output format
/// - If [sampleRate] and/or [channels] are provided, every segment is
///   resampled / down-mixed to them.
/// - If they are omitted, the output adopts the native sample rate and channel
///   count of the **first segment that has an audio track** (falling back to
///   `44100 Hz` / `2` channels when none of them do). This matches
///   [AudioExtractConfigs] so a single-segment merge is byte-for-byte identical
///   to [extractAudioToFile] for the uncompressed [AudioFormat.wav] format.
///
/// See [mergeAudioToFile] for the full contract.
class AudioMergeConfigs {
  /// Creates an [AudioMergeConfigs].
  ///
  /// [segments] The ordered, non-empty list of windows to concatenate.
  /// [format] The desired output audio format (default: [AudioFormat.wav]).
  /// [sampleRate] Optional uniform output sample rate in Hz (e.g. `16000`).
  /// [channels] Optional uniform output channel count (e.g. `1` = mono).
  /// [id] Unique task identifier. Generated automatically if not provided.
  AudioMergeConfigs({
    required this.segments,
    this.format = AudioFormat.wav,
    this.sampleRate,
    this.channels,
    String? id,
  }) : assert(
         sampleRate == null || sampleRate > 0,
         '[sampleRate] must be greater than 0',
       ),
       assert(channels == null || channels > 0, '[channels] must be > 0'),
       id = id ?? DateTime.now().millisecondsSinceEpoch.toString();

  /// The ordered list of windows to concatenate, in output order.
  final List<AudioMergeSegment> segments;

  /// The output audio format.
  ///
  /// **Default**: [AudioFormat.wav]
  final AudioFormat format;

  /// Optional uniform output sample rate in Hz.
  ///
  /// When set, every segment is resampled to this rate. When `null`, the
  /// output adopts the first audio-bearing segment's native rate (see the class
  /// docs).
  final int? sampleRate;

  /// Optional uniform output channel count (`1` = mono, `2` = stereo).
  ///
  /// When set, every segment is down-/up-mixed to this channel count. When
  /// `null`, the output adopts the first audio-bearing segment's native channel
  /// count.
  final int? channels;

  /// Unique identifier for tracking progress of this merge task.
  final String id;

  /// Whether the caller pinned an explicit uniform output format.
  bool get hasExplicitFormat => sampleRate != null || channels != null;

  /// Converts this configuration to a map for platform channel communication.
  ///
  /// [segmentInputPaths] must contain one resolved local file path per entry in
  /// [segments], in the same order (produced by [EditorVideo.safeFilePath]).
  Map<String, dynamic> toMap(List<String> segmentInputPaths) {
    assert(
      segmentInputPaths.length == segments.length,
      'Expected one resolved path per segment',
    );
    return {
      'id': id,
      'format': format.name,
      'sampleRate': sampleRate,
      'channels': channels,
      'segments': [
        for (var i = 0; i < segments.length; i++)
          segments[i].toMap(segmentInputPaths[i]),
      ],
    };
  }

  /// Creates a copy of this config with optional parameter overrides.
  AudioMergeConfigs copyWith({
    List<AudioMergeSegment>? segments,
    AudioFormat? format,
    int? sampleRate,
    int? channels,
    String? id,
  }) {
    return AudioMergeConfigs(
      segments: segments ?? this.segments,
      format: format ?? this.format,
      sampleRate: sampleRate ?? this.sampleRate,
      channels: channels ?? this.channels,
      id: id ?? this.id,
    );
  }

  @override
  String toString() {
    return 'AudioMergeConfigs(segments: ${segments.length}, format: $format, '
        'sampleRate: $sampleRate, channels: $channels, id: $id)';
  }
}
