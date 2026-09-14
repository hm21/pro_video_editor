import 'dart:typed_data';

import '../../platform/platform_interface.dart';
import 'thumbnail_configs_model.dart';

/// One decoded frame delivered by [ProVideoEditor.getThumbnailStream].
///
/// Frames arrive in decode order, not request order, so each one names the
/// [indices] into [ThumbnailConfigs.timestamps] it belongs to. Several
/// requested timestamps can resolve to the same source frame; those share one
/// event and one copy of [bytes].
///
/// Example usage:
/// ```dart
/// final frames = List<Uint8List?>.filled(configs.timestamps.length, null);
///
/// final stream = ProVideoEditor.instance.getThumbnailStream(configs);
///
/// await for (final frame in stream) {
///   for (final index in frame.indices) {
///     frames[index] = frame.bytes;
///   }
///   print('Progress: ${(frame.progress * 100).toStringAsFixed(0)}%');
/// }
/// ```
class ThumbnailFrame {
  /// Creates a [ThumbnailFrame].
  const ThumbnailFrame({
    required this.indices,
    required this.bytes,
    required this.progress,
  });

  /// Creates a [ThumbnailFrame] from a platform channel event map.
  ///
  /// The map should contain:
  /// - `indices`: List of int
  /// - `bytes`: Uint8List
  /// - `progress`: double
  factory ThumbnailFrame.fromMap(Map<dynamic, dynamic> map) {
    final rawIndices = map['indices'];
    if (rawIndices is! List) {
      throw ArgumentError(
        'Invalid indices data type: ${rawIndices.runtimeType}',
      );
    }
    final rawBytes = map['bytes'];
    if (rawBytes is! Uint8List) {
      throw ArgumentError('Invalid bytes data type: ${rawBytes.runtimeType}');
    }
    return ThumbnailFrame(
      indices: rawIndices
          .map((e) => (e as num).toInt())
          .toList(growable: false),
      bytes: rawBytes,
      progress: (map['progress'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Positions in [ThumbnailConfigs.timestamps] this frame was requested for.
  ///
  /// Never empty. Holds more than one entry when several requested timestamps
  /// resolve to the same source frame.
  final List<int> indices;

  /// The compressed image, in the configured [ThumbnailConfigs.outputFormat].
  final Uint8List bytes;

  /// Share of the requested timestamps resolved so far (0.0 to 1.0).
  ///
  /// Reaches 1.0 only when the last timestamp attempted produced a frame: a
  /// timestamp that cannot be decoded is skipped rather than delivered, so a
  /// request whose final timestamps fail closes below 1.0. Treat the stream
  /// closing as the end of the request, not this value.
  final double progress;

  @override
  String toString() =>
      'ThumbnailFrame(indices: $indices, bytes: ${bytes.length}, '
      'progress: ${progress.toStringAsFixed(2)})';
}
