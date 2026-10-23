import 'dart:ui';

import '../../../shared/utils/unique_task_id.dart';
import '../video/editor_video_model.dart';

/// Configuration for streaming every frame of a video range as raw luma.
///
/// Meant for motion analysis such as `VideoStabilizationAnalyzer`: frames are
/// decoded in one forward pass, turned upright and scaled down to fit
/// [outputSize], and delivered as 8-bit grayscale without any image
/// encoding.
class LumaFrameConfigs {
  /// Creates a [LumaFrameConfigs].
  LumaFrameConfigs({
    required this.video,
    required this.outputSize,
    this.startTime,
    this.endTime,
    this.maxFrameRate,
    this.maxParallelDecoders,
    String? id,
  }) : assert(
         maxParallelDecoders == null || maxParallelDecoders >= 1,
         '[maxParallelDecoders] must be at least 1',
       ),
       assert(
         maxFrameRate == null || maxFrameRate > 0,
         '[maxFrameRate] must be positive',
       ),
       assert(
         startTime == null || endTime == null || endTime > startTime,
         '[endTime] must be after [startTime]',
       ),
       id = id ?? uniqueTaskId();

  /// Unique ID for the task, used to cancel it.
  final String id;

  /// The video to read.
  final EditorVideo video;

  /// The box the upright frames are scaled into, keeping their aspect ratio:
  /// a frame is as large as fits, so one side matches the box.
  final Size outputSize;

  /// The first source time to deliver; the start of the video when null.
  final Duration? startTime;

  /// The source time to stop before; the end of the video when null.
  final Duration? endTime;

  /// Skips frames that follow the previous delivered one by less than
  /// `1 / maxFrameRate` seconds, so a 60 fps clip can be analyzed at 30.
  /// Every frame is delivered when null.
  final double? maxFrameRate;

  /// Upper bound of hardware decoder sessions the extraction may run at
  /// once. Pass `1` while a player shares the decoder pool; null keeps the
  /// platform default. Only Android has parallel decoder sessions; the other
  /// platforms ignore the value.
  final int? maxParallelDecoders;

  /// Serializes the configuration for the platform channel.
  Map<String, dynamic> toMap() => {
    'id': id,
    'outputWidth': outputSize.width.round(),
    'outputHeight': outputSize.height.round(),
    if (startTime != null) 'startUs': startTime!.inMicroseconds,
    if (endTime != null) 'endUs': endTime!.inMicroseconds,
    if (maxFrameRate != null) 'maxFrameRate': maxFrameRate,
    if (maxParallelDecoders != null) 'maxParallelDecoders': maxParallelDecoders,
  };
}
