import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import '../models/frame/luma_frame_configs_model.dart';
import '../models/video/editor_video_model.dart';
import '../models/video/video_stabilization_model.dart';
import '../platform/platform_interface.dart';
import 'video_stabilization_analyzer.dart';

/// Streams the frames of [video] and analyzes them in a background isolate,
/// so decoding and analysis overlap and the calling isolate stays free.
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
}) async {
  final fromWorker = ReceivePort();
  final isolate = await Isolate.spawn(_worker, (
    fromWorker.sendPort,
    maxZoom,
    smoothing.inMicroseconds,
  ), errorsAreFatal: true);
  final replies = StreamIterator<Object?>(fromWorker);
  try {
    if (!await replies.moveNext()) throw StateError('Analysis did not start');
    final toWorker = replies.current! as SendPort;

    await for (final frame in ProVideoEditor.instance.getLumaFrameStream(
      LumaFrameConfigs(
        video: video,
        outputSize: frameSize,
        startTime: startTime,
        endTime: endTime,
        maxFrameRate: maxFrameRate,
        maxParallelDecoders: maxParallelDecoders,
        id: id,
      ),
    )) {
      toWorker.send((
        TransferableTypedData.fromList([frame.bytes]),
        frame.width,
        frame.height,
        frame.time.inMicroseconds,
      ));
      onProgress?.call(frame.progress);
    }
    toWorker.send(null);

    if (!await replies.moveNext()) throw StateError('Analysis ended early');
    final reply = replies.current;
    if (reply is Map<String, dynamic>) return VideoStabilization.fromMap(reply);
    final (error, stack) = reply! as (String, String);
    throw StateError('Stabilization analysis failed: $error\n$stack');
  } finally {
    await replies.cancel();
    fromWorker.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

/// Runs a [VideoStabilizationAnalyzer] over the frames it is sent, until a
/// `null` asks for the result.
Future<void> _worker((SendPort, double, int) setup) async {
  final (reply, maxZoom, smoothingUs) = setup;
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  VideoStabilizationAnalyzer? analyzer;
  try {
    await for (final message in inbox) {
      if (message == null) break;
      final (data, width, height, timeUs) =
          message as (TransferableTypedData, int, int, int);
      analyzer ??= VideoStabilizationAnalyzer(
        width: width,
        height: height,
        maxZoom: maxZoom,
        smoothing: Duration(microseconds: smoothingUs),
      );
      analyzer.addFrame(
        data.materialize().asUint8List(),
        Duration(microseconds: timeUs),
      );
    }
    if (analyzer == null) throw StateError('No frames were decoded');
    reply.send(analyzer.finish().toMap());
  } catch (error, stack) {
    reply.send((error.toString(), stack.toString()));
  } finally {
    inbox.close();
  }
}
