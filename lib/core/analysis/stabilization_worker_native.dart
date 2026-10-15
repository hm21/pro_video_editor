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
  final worker = Completer<SendPort>();
  final result = Completer<VideoStabilization>();
  // Both are awaited below; a failure that arrives before that must not count
  // as unhandled in the meantime.
  worker.future.ignore();
  result.future.ignore();
  void fail(Object error) {
    if (!worker.isCompleted) worker.completeError(error);
    if (!result.isCompleted) result.completeError(error);
  }

  fromWorker.listen((message) {
    if (message is SendPort) {
      worker.complete(message);
    } else if (message is Map<String, dynamic>) {
      if (!result.isCompleted) {
        result.complete(VideoStabilization.fromMap(message));
      }
    } else if (message is (String, String)) {
      fail(
        StateError(
          'Stabilization analysis failed: ${message.$1}\n${message.$2}',
        ),
      );
    } else if (message is List) {
      // An error the worker did not catch, sent by `onError`.
      fail(StateError('Stabilization analysis failed: ${message.first}'));
    } else {
      // `onExit`: the worker ended without an answer, e.g. out of memory.
      fail(StateError('Stabilization analysis ended early'));
    }
  });
  final isolate = await Isolate.spawn(
    _worker,
    (fromWorker.sendPort, maxZoom, smoothing.inMicroseconds),
    errorsAreFatal: true,
    onError: fromWorker.sendPort,
    onExit: fromWorker.sendPort,
  );
  try {
    final toWorker = await worker.future;
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
      // The worker failed: stop decoding, which cancels the native task.
      if (result.isCompleted) break;
      toWorker.send((
        TransferableTypedData.fromList([frame.bytes]),
        frame.width,
        frame.height,
        frame.time.inMicroseconds,
      ));
      onProgress?.call(frame.progress);
    }
    toWorker.send(null);
    return await result.future;
  } finally {
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
