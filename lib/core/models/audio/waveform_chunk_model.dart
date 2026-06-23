import 'dart:typed_data';

/// Represents a chunk of waveform data received during streaming.
///
/// When using [ProVideoEditor.getWaveformStream], waveform data is delivered
/// progressively in chunks. Each chunk contains a portion of the audio's
/// peak amplitudes along with metadata about its position in the full waveform.
///
/// Example usage:
/// ```dart
/// final stream = ProVideoEditor.instance.getWaveformStream(configs);
///
/// await for (final chunk in stream) {
///   print('Received ${chunk.sampleCount} samples');
///   print('Progress: ${(chunk.progress * 100).toStringAsFixed(0)}%');
///
///   // Append to your waveform display
///   appendToWaveform(chunk.leftChannel, chunk.rightChannel);
/// }
/// ```
class WaveformChunk {
  /// Creates a [WaveformChunk] instance.
  ///
  /// [leftChannel] Peak amplitudes for left (or mono) channel in this chunk.
  /// [rightChannel] Peak amplitudes for right channel (null for mono).
  /// [startIndex] The starting sample index in the full waveform.
  /// [progress] Current generation progress (0.0 to 1.0).
  /// [sampleRate] Original audio sample rate in Hz.
  /// [totalDuration] Total audio duration.
  /// [samplesPerSecond] Number of waveform samples per second.
  /// [isComplete] Whether this is the final chunk.
  const WaveformChunk({
    required this.leftChannel,
    this.rightChannel,
    required this.startIndex,
    required this.progress,
    required this.sampleRate,
    required this.totalDuration,
    required this.samplesPerSecond,
    this.isComplete = false,
  });

  /// Creates a [WaveformChunk] from a platform channel event map.
  ///
  /// The map should contain:
  /// - `leftChannel`: List or Float32List
  /// - `rightChannel`: List or Float32List (optional)
  /// - `startIndex`: int
  /// - `progress`: double
  /// - `sampleRate`: int
  /// - `totalDuration`: int (milliseconds, converted to Duration)
  /// - `samplesPerSecond`: int
  /// - `isComplete`: bool (optional)
  factory WaveformChunk.fromMap(Map<dynamic, dynamic> map) {
    final leftData = map['leftChannel'];
    final rightData = map['rightChannel'];

    Float32List leftChannel;
    if (leftData is Float32List) {
      leftChannel = leftData;
    } else if (leftData is List) {
      leftChannel = Float32List.fromList(
        leftData.map((e) => (e as num).toDouble()).toList(),
      );
    } else {
      throw ArgumentError(
        'Invalid leftChannel data type: ${leftData.runtimeType}',
      );
    }

    Float32List? rightChannel;
    if (rightData != null) {
      if (rightData is Float32List) {
        rightChannel = rightData;
      } else if (rightData is List) {
        rightChannel = Float32List.fromList(
          rightData.map((e) => (e as num).toDouble()).toList(),
        );
      }
    }

    return WaveformChunk(
      leftChannel: leftChannel,
      rightChannel: rightChannel,
      startIndex: (map['startIndex'] as num).toInt(),
      progress: (map['progress'] as num).toDouble(),
      sampleRate: (map['sampleRate'] as num).toInt(),
      totalDuration: Duration(
        milliseconds: (map['totalDuration'] as num).toInt(),
      ),
      samplesPerSecond: (map['samplesPerSecond'] as num).toInt(),
      isComplete: map['isComplete'] as bool? ?? false,
    );
  }

  /// Peak amplitudes for the left channel (or mono channel) in this chunk.
  ///
  /// Values are normalized to [0.0, 1.0].
  final Float32List leftChannel;

  /// Peak amplitudes for the right channel in this chunk.
  ///
  /// Null for mono audio sources. Values are normalized to [0.0, 1.0].
  final Float32List? rightChannel;

  /// The starting sample index of this chunk in the full waveform.
  ///
  /// Use this to correctly position the chunk when building the complete
  /// waveform visualization.
  final int startIndex;

  /// Current generation progress (0.0 to 1.0).
  ///
  /// This represents how much of the total audio has been processed.
  final double progress;

  /// Original audio sample rate in Hz (e.g., 44100, 48000).
  final int sampleRate;

  /// Total audio duration.
  ///
  /// This is the duration of the entire audio, not just this chunk.
  final Duration totalDuration;

  /// Number of waveform samples per second of audio.
  final int samplesPerSecond;

  /// Whether this is the final chunk in the stream.
  ///
  /// When true, this chunk completes the waveform generation.
  final bool isComplete;

  /// Number of samples in this chunk.
  int get sampleCount => leftChannel.length;

  /// Whether this is stereo audio (has separate left/right channels).
  bool get isStereo => rightChannel != null;

  /// The ending sample index of this chunk (exclusive).
  int get endIndex => startIndex + sampleCount;

  @override
  String toString() {
    return 'WaveformChunk('
        'samples: $sampleCount, '
        'startIndex: $startIndex, '
        'progress: ${(progress * 100).toStringAsFixed(1)}%, '
        'stereo: $isStereo, '
        'isComplete: $isComplete)';
  }
}
