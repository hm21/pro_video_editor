import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../models/exceptions/render_exceptions.dart';
import '../models/frame/luma_frame_configs_model.dart';
import '../models/frame/luma_frame_model.dart';
import '../models/video/editor_video_model.dart';
import '../models/video/video_object_track_model.dart';
import '../platform/platform_interface.dart';
import 'video_object_tracker.dart';

/// Tags a frame that follows the marked one.
const int _forward = 0;

/// Tags a frame that precedes the marked one.
const int _backward = 1;

/// How much of the range before the marked frame is decoded at a time. The
/// decoder only runs forward, so that range is read in pieces from the end,
/// and each piece is handed to the tracker last frame first. Longer pieces
/// decode faster but hold more frames in memory.
const Duration _backwardChunk = Duration(seconds: 2);

/// Ids of the [trackVideoInBackground] calls running now.
final Set<String> _running = {};

/// Ids of running calls that were asked to stop.
final Set<String> _canceled = {};

/// The task id of the frame stream each running call reads from last.
final Map<String, String> _decoding = {};

/// Counts the frame streams started, so each gets its own task id.
int _streams = 0;

/// Stops the [trackVideoInBackground] call started with [id].
Future<void> cancelTrackVideo(String id) async {
  if (!_running.contains(id)) return;
  _canceled.add(id);
  final stream = _decoding[id];
  if (stream == null) return;
  try {
    await ProVideoEditor.instance.cancel(stream);
  } on PlatformException {
    // Between two pieces of the backward pass no decoder runs; the call
    // stops before it starts the next one.
  }
}

/// Streams the frames of [video] around [anchorTime] and follows [region]
/// through them in a background isolate, so decoding and tracking overlap
/// and the calling isolate stays free.
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
}) async {
  final fromWorker = ReceivePort();
  final worker = Completer<SendPort>();
  final result = Completer<VideoObjectTrack>();
  // Both are awaited below; a failure that arrives before that must not count
  // as unhandled in the meantime.
  worker.future.ignore();
  result.future.ignore();
  var forwardLost = false;
  var backwardLost = false;
  void fail(Object error) {
    if (!worker.isCompleted) worker.completeError(error);
    if (!result.isCompleted) result.completeError(error);
  }

  fromWorker.listen((message) {
    if (message is SendPort) {
      worker.complete(message);
    } else if (message is Map<String, dynamic>) {
      if (!result.isCompleted) {
        result.complete(VideoObjectTrack.fromMap(message));
      }
    } else if (message is int) {
      if (message == _forward) {
        forwardLost = true;
      } else {
        backwardLost = true;
      }
    } else if (message is (String, String)) {
      fail(StateError('Object tracking failed: ${message.$1}\n${message.$2}'));
    } else if (message is List) {
      // An error the worker did not catch, sent by `onError`.
      fail(StateError('Object tracking failed: ${message.first}'));
    } else {
      // `onExit`: the worker ended without an answer, e.g. out of memory.
      fail(StateError('Object tracking ended early'));
    }
  });

  _running.add(id);
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(
      _worker,
      (
        fromWorker.sendPort,
        region.left,
        region.top,
        region.right,
        region.bottom,
        smoothing.inMicroseconds,
      ),
      errorsAreFatal: true,
      onError: fromWorker.sendPort,
      onExit: fromWorker.sendPort,
    );
    final toWorker = await worker.future;
    void send(int direction, LumaFrame frame) => toWorker.send((
      direction,
      TransferableTypedData.fromList([frame.bytes]),
      frame.width,
      frame.height,
      frame.time.inMicroseconds,
    ));
    Stream<LumaFrame> frames(Duration from, Duration? to) {
      if (_canceled.contains(id)) throw const RenderCanceledException();
      // Every stream runs under a task id of its own: a stream left early
      // (the object was lost) is still being torn down natively when the
      // next one starts, and native refuses a second task under its id.
      final stream = '$id-${_streams++}';
      _decoding[id] = stream;
      return ProVideoEditor.instance.getLumaFrameStream(
        LumaFrameConfigs(
          video: video,
          outputSize: frameSize,
          startTime: from,
          endTime: to,
          maxFrameRate: maxFrameRate,
          maxParallelDecoders: maxParallelDecoders,
          id: stream,
        ),
      );
    }

    final floor = startTime ?? Duration.zero;
    // A mark outside the range is taken on the range's nearest end.
    var anchorAt = anchorTime < floor ? floor : anchorTime;
    if (endTime != null && anchorAt > endTime) anchorAt = endTime;
    // The share of the progress the forward pass takes, by the length of
    // the range it covers.
    final forwardShare = endTime == null
        ? 0.5
        : (endTime - anchorAt).inMicroseconds /
              math.max(1, (endTime - floor).inMicroseconds);

    Duration? anchorFrameTime;
    PlatformException? forwardError;
    if (endTime == null || anchorAt < endTime) {
      try {
        await for (final frame in frames(anchorAt, endTime)) {
          // The worker failed: stop decoding, which cancels the native task.
          if (result.isCompleted) break;
          anchorFrameTime ??= frame.time;
          send(_forward, frame);
          onProgress?.call(frame.progress * forwardShare);
          if (forwardLost) break;
        }
      } on PlatformException catch (error) {
        // Native refuses a range without frames, as when the mark lies past
        // the last frame. The backward pass then starts from the last one;
        // when it finds none either, this was the real failure.
        if (anchorFrameTime != null) rethrow;
        forwardError = error;
      }
    }

    // Without a frame at or after the anchor, the last one before it is the
    // marked frame, and the backward pass starts with it. Each piece reaches
    // up to and includes the earliest frame handed over so far, which is
    // skipped: native refuses a range without frames, and one that stopped
    // short of that frame may hold none (before the first frame of the video
    // or of the range).
    final anchor = anchorFrameTime ?? anchorAt;
    final backwardSpan = math.max(1, (anchor - floor).inMicroseconds);
    var earliest = anchorFrameTime;
    var cursor = anchor;
    while (cursor > floor && !backwardLost && !result.isCompleted) {
      final from = cursor - _backwardChunk > floor
          ? cursor - _backwardChunk
          : floor;
      final List<LumaFrame> chunk;
      try {
        chunk = await frames(
          from,
          earliest == null
              ? cursor
              : earliest + const Duration(microseconds: 1),
        ).toList();
      } on PlatformException {
        if (earliest == null && forwardError != null) throw forwardError;
        rethrow;
      }
      for (final frame in chunk.reversed) {
        if (backwardLost || result.isCompleted) break;
        if (earliest != null && frame.time >= earliest) continue;
        send(_backward, frame);
        onProgress?.call(
          forwardShare +
              (1 - forwardShare) *
                  (anchor - frame.time).inMicroseconds /
                  backwardSpan,
        );
      }
      if (chunk.isNotEmpty &&
          (earliest == null || chunk.first.time < earliest)) {
        earliest = chunk.first.time;
      }
      cursor = from;
    }
    // A cancel that came after the last frames were read.
    if (_canceled.contains(id)) throw const RenderCanceledException();
    toWorker.send(null);
    final track = await result.future;
    onProgress?.call(1);
    return track;
  } finally {
    _running.remove(id);
    _canceled.remove(id);
    _decoding.remove(id);
    fromWorker.close();
    isolate?.kill(priority: Isolate.immediate);
  }
}

/// Follows the region through the frames it is sent, forward and backward
/// from the first one, until a `null` asks for the result.
Future<void> _worker(
  (SendPort, double, double, double, double, int) setup,
) async {
  final (reply, left, top, right, bottom, smoothingUs) = setup;
  final region = Rect.fromLTRB(left, top, right, bottom);
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  VideoObjectTracker? forward;
  VideoObjectTracker? backward;
  ObjectTrackSample? anchor;
  final after = <ObjectTrackSample>[];
  final before = <ObjectTrackSample>[];
  try {
    await for (final message in inbox) {
      if (message == null) break;
      final (direction, data, width, height, timeUs) =
          message as (int, TransferableTypedData, int, int, int);
      final luma = data.materialize().asUint8List();
      final time = Duration(microseconds: timeUs);
      if (anchor == null) {
        forward = VideoObjectTracker(
          width: width,
          height: height,
          region: region,
        );
        backward = VideoObjectTracker(
          width: width,
          height: height,
          region: region,
        );
        anchor = forward.addFrame(luma, time);
        backward.addFrame(luma, time);
        continue;
      }
      final tracker = direction == _forward ? forward! : backward!;
      if (tracker.isLost) continue;
      final sample = tracker.addFrame(luma, time);
      if (sample != null) {
        (direction == _forward ? after : before).add(sample);
      }
      if (tracker.isLost) reply.send(direction);
    }
    if (anchor == null) throw StateError('No frames were decoded');
    var track = VideoObjectTrack(
      samples: [...before.reversed, anchor, ...after],
      anchorTime: anchor.time,
      // The object was not found in the last frames before the range ended:
      // it was on its way out of view.
      reachedStart: !backward!.isLost && backward.missedFrames == 0,
      reachedEnd: !forward!.isLost && forward.missedFrames == 0,
    );
    if (smoothingUs > 0) {
      track = track.smoothed(position: Duration(microseconds: smoothingUs));
    }
    reply.send(track.toMap());
  } catch (error, stack) {
    reply.send((error.toString(), stack.toString()));
  } finally {
    inbox.close();
  }
}
