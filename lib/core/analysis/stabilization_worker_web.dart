import 'dart:ui';

import '../models/video/editor_video_model.dart';
import '../models/video/video_stabilization_model.dart';

/// Web stand-in: frames cannot be streamed on the web.
Future<VideoStabilization> analyzeVideoInBackground({
  required EditorVideo video,
  required Size frameSize,
  required double maxZoom,
  required Duration smoothing,
  Duration? startTime,
  Duration? endTime,
  double? maxFrameRate,
  int? maxParallelDecoders,
  String? id,
  void Function(double progress)? onProgress,
}) {
  throw UnsupportedError('Video stabilization is not supported on the web');
}
