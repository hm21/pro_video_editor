import '/shared/utils/parser/int_parser.dart';

/// Where a single input segment ended up in a merged audio file.
///
/// Produced by [mergeAudioToFile], one entry per input segment, in input order.
/// Because segments are concatenated with no gaps, [outputStart] always equals
/// the sum of the [outputDuration]s of the preceding segments.
class AudioMergeSegmentOffset {
  /// Creates an [AudioMergeSegmentOffset].
  const AudioMergeSegmentOffset({
    required this.outputStart,
    required this.outputDuration,
  });

  /// Builds an offset from a platform-channel map with microsecond values.
  factory AudioMergeSegmentOffset.fromMap(Map<dynamic, dynamic> map) {
    return AudioMergeSegmentOffset(
      outputStart: Duration(microseconds: safeParseInt(map['outputStartUs'])),
      outputDuration: Duration(
        microseconds: safeParseInt(map['outputDurationUs']),
      ),
    );
  }

  /// Where this segment begins in the merged output file.
  final Duration outputStart;

  /// The played length of this segment in the merged output file
  /// (`≈ (endTime - startTime) / speed`).
  final Duration outputDuration;

  /// Where this segment ends in the merged output file
  /// (`outputStart + outputDuration`).
  Duration get outputEnd => outputStart + outputDuration;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AudioMergeSegmentOffset &&
        other.outputStart == outputStart &&
        other.outputDuration == outputDuration;
  }

  @override
  int get hashCode => outputStart.hashCode ^ outputDuration.hashCode;

  @override
  String toString() =>
      'AudioMergeSegmentOffset(outputStart: $outputStart, '
      'outputDuration: $outputDuration)';
}

/// The result of a [mergeAudioToFile] call.
///
/// Contains the written [outputPath], the total merged [totalDuration], and a
/// per-input-segment [segments] offset map that lets callers translate a
/// timestamp in the merged file back onto the segment (and thus the source
/// clip) it came from.
class AudioMergeResult {
  /// Creates an [AudioMergeResult].
  const AudioMergeResult({
    required this.outputPath,
    required this.segments,
    required this.totalDuration,
  });

  /// Builds a result from the native platform-channel response.
  factory AudioMergeResult.fromMap(Map<dynamic, dynamic> map) {
    final rawSegments = (map['segments'] as List<dynamic>? ?? const [])
        .cast<Map<dynamic, dynamic>>();
    return AudioMergeResult(
      outputPath: map['outputPath'] as String,
      totalDuration: Duration(
        microseconds: safeParseInt(map['totalDurationUs']),
      ),
      segments: [
        for (final entry in rawSegments) AudioMergeSegmentOffset.fromMap(entry),
      ],
    );
  }

  /// Absolute path of the merged audio file that was written.
  final String outputPath;

  /// One entry per input segment, in input order.
  ///
  /// `segments[i].outputStart` is where segment `i` begins in [outputPath];
  /// `segments[i].outputDuration` is its played length. Since there are no gaps
  /// between segments, `segments[i].outputStart` equals the sum of the
  /// durations of segments `0..i-1`.
  final List<AudioMergeSegmentOffset> segments;

  /// Total length of the merged output — the sum of every segment's
  /// [AudioMergeSegmentOffset.outputDuration].
  final Duration totalDuration;

  @override
  String toString() =>
      'AudioMergeResult(outputPath: $outputPath, '
      'segments: ${segments.length}, totalDuration: $totalDuration)';
}
