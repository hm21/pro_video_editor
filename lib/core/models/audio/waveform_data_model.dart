import 'dart:typed_data';

/// Represents waveform data extracted from an audio source.
///
/// Contains peak amplitude samples that can be used for rendering
/// a visual representation of audio. The data is normalized to the
/// range [0.0, 1.0] where 0.0 is silence and 1.0 is maximum amplitude.
///
/// For stereo audio, both [leftChannel] and [rightChannel] will contain
/// data. For mono audio, [rightChannel] will be null.
///
/// Example usage:
/// ```dart
/// final waveform = await ProVideoEditor.instance.getWaveform(configs);
///
/// // Access samples
/// for (int i = 0; i < waveform.sampleCount; i++) {
///   final leftPeak = waveform.leftChannel[i];
///   final rightPeak = waveform.rightChannel?[i];
///   // Render peak...
/// }
/// ```
class WaveformData {
  /// Creates a [WaveformData] instance.
  ///
  /// [leftChannel] Peak amplitudes for left (or mono) channel.
  /// [rightChannel] Peak amplitudes for right channel (null for mono).
  /// [sampleRate] Original audio sample rate in Hz.
  /// [duration] Total duration in milliseconds.
  /// [samplesPerSecond] Number of waveform samples per second of audio.
  const WaveformData({
    required this.leftChannel,
    this.rightChannel,
    required this.sampleRate,
    required this.duration,
    required this.samplesPerSecond,
  });

  /// Creates a [WaveformData] from a platform channel response map.
  ///
  /// The map should contain:
  /// - `leftChannel`: List or Float32List
  /// - `rightChannel`: List or Float32List (optional)
  /// - `sampleRate`: int
  /// - `duration`: int (milliseconds)
  /// - `samplesPerSecond`: int
  factory WaveformData.fromMap(Map<dynamic, dynamic> map) {
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

    return WaveformData(
      leftChannel: leftChannel,
      rightChannel: rightChannel,
      sampleRate: (map['sampleRate'] as num).toInt(),
      duration: Duration(milliseconds: (map['duration'] as num).toInt()),
      samplesPerSecond: (map['samplesPerSecond'] as num).toInt(),
    );
  }

  /// Peak amplitudes for the left channel (or mono channel).
  ///
  /// Values are normalized to [0.0, 1.0].
  final Float32List leftChannel;

  /// Peak amplitudes for the right channel.
  ///
  /// Null for mono audio sources. Values are normalized to [0.0, 1.0].
  final Float32List? rightChannel;

  /// Original audio sample rate in Hz (e.g., 44100, 48000).
  final int sampleRate;

  /// Total audio duration.
  final Duration duration;

  /// Number of waveform samples per second of audio.
  ///
  /// This determines the resolution of the waveform. Higher values
  /// provide more detail but increase memory usage.
  final int samplesPerSecond;

  /// Number of samples in this waveform.
  int get sampleCount => leftChannel.length;

  /// Whether this is stereo audio (has separate left/right channels).
  bool get isStereo => rightChannel != null;

  /// Duration per sample in milliseconds.
  double get millisecondsPerSample =>
      sampleCount > 0 ? duration.inMilliseconds / sampleCount : 0;

  /// Returns a downsampled version of this waveform for lower resolutions.
  ///
  /// Useful for zoom-out scenarios where full resolution is not needed.
  ///
  /// [targetSamplesPerSecond] The desired samples per second for the result.
  /// Must be less than or equal to [samplesPerSecond].
  WaveformData downsample(int targetSamplesPerSecond) {
    if (targetSamplesPerSecond >= samplesPerSecond) {
      return this;
    }

    final ratio = samplesPerSecond / targetSamplesPerSecond;
    final newLength = (sampleCount / ratio).ceil();

    final newLeft = Float32List(newLength);
    final newRight = rightChannel != null ? Float32List(newLength) : null;

    for (int i = 0; i < newLength; i++) {
      final start = (i * ratio).floor();
      final end = ((i + 1) * ratio).floor().clamp(0, sampleCount);

      // Find max peak in this block
      double maxLeft = 0;
      double maxRight = 0;

      for (int j = start; j < end; j++) {
        if (leftChannel[j] > maxLeft) maxLeft = leftChannel[j];
        if (rightChannel != null && rightChannel![j] > maxRight) {
          maxRight = rightChannel![j];
        }
      }

      newLeft[i] = maxLeft;
      if (newRight != null) newRight[i] = maxRight;
    }

    return WaveformData(
      leftChannel: newLeft,
      rightChannel: newRight,
      sampleRate: sampleRate,
      duration: duration,
      samplesPerSecond: targetSamplesPerSecond,
    );
  }

  /// Gets a range of samples for a specific time range.
  ///
  /// [start] Start time.
  /// [end] End time.
  ///
  /// Returns a new [WaveformData] containing only the specified range.
  WaveformData getRange(Duration start, Duration end) {
    final startSample = (start.inMilliseconds / millisecondsPerSample)
        .floor()
        .clamp(0, sampleCount);
    final endSample = (end.inMilliseconds / millisecondsPerSample).ceil().clamp(
          0,
          sampleCount,
        );
    final length = endSample - startSample;

    if (length <= 0) {
      return WaveformData(
        leftChannel: Float32List(0),
        rightChannel: rightChannel != null ? Float32List(0) : null,
        sampleRate: sampleRate,
        duration: Duration.zero,
        samplesPerSecond: samplesPerSecond,
      );
    }

    return WaveformData(
      leftChannel: leftChannel.sublist(startSample, endSample),
      rightChannel: rightChannel?.sublist(startSample, endSample),
      sampleRate: sampleRate,
      duration: end - start,
      samplesPerSecond: samplesPerSecond,
    );
  }

  @override
  String toString() {
    return 'WaveformData('
        'samples: $sampleCount, '
        'stereo: $isStereo, '
        'duration: $duration, '
        'sampleRate: ${sampleRate}Hz, '
        'samplesPerSecond: $samplesPerSecond)';
  }
}
