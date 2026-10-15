import 'package:flutter/foundation.dart';

/// One decoded frame as raw 8-bit luma, emitted by
/// `ProVideoEditor.getLumaFrameStream`.
class LumaFrame {
  /// Creates a [LumaFrame].
  const LumaFrame({
    required this.time,
    required this.width,
    required this.height,
    required this.bytes,
    required this.progress,
  });

  /// Creates a [LumaFrame] from a platform channel event map.
  factory LumaFrame.fromMap(Map<dynamic, dynamic> map) {
    final bytes = map['bytes'];
    if (bytes is! Uint8List) {
      throw ArgumentError('Invalid bytes data type: ${bytes.runtimeType}');
    }
    final width = (map['width'] as num).toInt();
    final height = (map['height'] as num).toInt();
    if (bytes.length < width * height) {
      throw ArgumentError(
        'Frame of $width x $height carries only ${bytes.length} bytes',
      );
    }
    return LumaFrame(
      time: Duration(microseconds: (map['ptsUs'] as num).toInt()),
      width: width,
      height: height,
      bytes: bytes,
      progress: (map['progress'] as num?)?.toDouble() ?? 0,
    );
  }

  /// The frame's presentation time in the source video.
  final Duration time;

  /// Width in pixels, upright as the video is displayed.
  final int width;

  /// Height in pixels, upright as the video is displayed.
  final int height;

  /// Row-major luma, one byte per pixel, `width * height` bytes.
  final Uint8List bytes;

  /// Share of the requested range decoded so far (0.0 to 1.0).
  final double progress;

  @override
  String toString() =>
      'LumaFrame(time: $time, ${width}x$height, '
      'progress: ${progress.toStringAsFixed(2)})';
}
