import 'dart:typed_data';
import 'dart:ui';

import '../models/video/editor_video_model.dart';
import '../models/video/video_stabilization_model.dart';
import 'camera_path_smoother.dart';
import 'frame_motion_estimator.dart';
import 'stabilization_worker_web.dart'
    if (dart.library.io) 'stabilization_worker_native.dart';

/// Measures camera shake in a sequence of frames and plans the transforms
/// that steady it.
///
/// Feed every frame of the range to stabilize, in order, as small 8-bit luma
/// buffers (around 320 pixels on the long side is plenty), then call
/// [finish]. The analysis is classical motion estimation — corners tracked
/// from frame to frame — and runs entirely in Dart; it is CPU-bound, so run
/// it in a background isolate.
///
/// The frames must be upright (as displayed) and all the same size. Their
/// aspect ratio must match the video's, since the offsets in the result are
/// fractions of the frame size.
class VideoStabilizationAnalyzer {
  /// Creates an analyzer for frames of [width] × [height] pixels.
  VideoStabilizationAnalyzer({
    required this.width,
    required this.height,
    this.maxZoom = 1.15,
    this.smoothing = const Duration(seconds: 1),
  }) : assert(maxZoom >= 1, '[maxZoom] must be at least 1'),
       _estimator = FrameMotionEstimator(width: width, height: height);

  /// Analyzes [video] end to end: streams its frames with
  /// `ProVideoEditor.getLumaFrameStream` and runs the analysis in a
  /// background isolate while they decode.
  ///
  /// [startTime] and [endTime] limit the range, as in a `VideoSegment`; the
  /// result covers only those frames, so trim the analysis to the part the
  /// render will show. [frameSize] bounds the analyzed frames — around 320
  /// pixels on the long side is plenty. [onProgress] reports the share of
  /// the range decoded so far.
  ///
  /// Cancel with `ProVideoEditor.cancel` and the same [id]; the future then
  /// fails with a `RenderCanceledException`.
  ///
  /// Throws a `PlatformException` when the video cannot be decoded and an
  /// [UnsupportedError] on the web.
  static Future<VideoStabilization> analyzeVideo(
    EditorVideo video, {
    Duration? startTime,
    Duration? endTime,
    double maxZoom = 1.15,
    Duration smoothing = const Duration(seconds: 1),
    Size frameSize = const Size(320, 320),
    double? maxFrameRate,
    int? maxParallelDecoders,
    String? id,
    void Function(double progress)? onProgress,
  }) => analyzeVideoInBackground(
    video: video,
    frameSize: frameSize,
    maxZoom: maxZoom,
    smoothing: smoothing,
    startTime: startTime,
    endTime: endTime,
    maxFrameRate: maxFrameRate,
    maxParallelDecoders: maxParallelDecoders,
    id: id,
    onProgress: onProgress,
  );

  /// Frame width in pixels.
  final int width;

  /// Frame height in pixels.
  final int height;

  /// The most the result may zoom in to hide the borders. Where a steadier
  /// path would need more, the correction is reduced and some shake stays.
  final double maxZoom;

  /// How strongly the camera path is smoothed: the standard deviation of the
  /// smoothing window. Longer smoothing removes slower sway too, but needs
  /// more zoom.
  final Duration smoothing;

  final FrameMotionEstimator _estimator;
  final List<FrameMotion> _motions = [];
  final List<Duration> _times = [];

  /// How many frames were added so far.
  int get frameCount => _times.length;

  /// Adds the next frame. [luma] is row-major, one byte per pixel; [time] is
  /// the frame's source timestamp.
  void addFrame(Uint8List luma, Duration time) {
    if (luma.length < width * height) {
      throw ArgumentError.value(
        luma.length,
        'luma',
        'expected $width x $height = ${width * height} bytes',
      );
    }
    if (_times.isNotEmpty && time <= _times.last) {
      throw ArgumentError.value(time, 'time', 'frames must arrive in order');
    }
    final motion = _estimator.addFrame(luma);
    if (motion != null) _motions.add(motion);
    _times.add(time);
  }

  /// Plans the stabilization for the frames added so far.
  ///
  /// Throws a [StateError] when fewer than two frames were added.
  VideoStabilization finish() {
    if (_times.length < 2) {
      throw StateError('Stabilization needs at least two frames');
    }
    final plan = CameraPathSmoother(
      smoothingFrames: smoothing.inMicroseconds / _medianFrameDurationUs(),
      maxZoom: maxZoom,
    ).plan(_motions, width, height);
    return VideoStabilization(
      zoom: plan.zoom,
      unreliableFrames: plan.unreliableFrames,
      attenuatedFrames: plan.attenuatedFrames,
      keyframes: [
        for (var i = 0; i < _times.length; i++)
          StabilizationKeyframe(
            time: _times[i],
            offset: Offset(plan.warps[i].tx / width, plan.warps[i].ty / height),
            rotation: plan.warps[i].angle,
            scale: plan.warps[i].scale,
          ),
      ],
    );
  }

  double _medianFrameDurationUs() {
    final deltas = [
      for (var i = 1; i < _times.length; i++)
        (_times[i] - _times[i - 1]).inMicroseconds,
    ]..sort();
    final median = deltas[deltas.length ~/ 2];
    return median <= 0 ? 33333 : median.toDouble();
  }
}
