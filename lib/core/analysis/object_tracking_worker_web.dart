import 'dart:ui';

import '../models/video/editor_video_model.dart';
import '../models/video/video_object_track_model.dart';

/// Web stand-in: frames cannot be streamed on the web.
Future<VideoObjectTrack> trackVideoInBackground({
  required EditorVideo video,
  required Rect region,
  required Duration anchorTime,
  required Size frameSize,
  required Duration smoothing,
  required String id,
  Duration? startTime,
  Duration? endTime,
  double? maxFrameRate,
  int? maxParallelDecoders,
  void Function(double progress)? onProgress,
}) {
  throw UnsupportedError('Object tracking is not supported on the web');
}

/// Web stand-in: nothing runs that could be cancelled.
Future<void> cancelTrackVideo(String id) async {}
