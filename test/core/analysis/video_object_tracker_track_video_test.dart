import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

import 'synthetic_scene.dart';

const _width = 240;
const _height = 136;
const _fps = 30;

Duration _frameTime(int frame) =>
    Duration(microseconds: (frame * 1e6 / _fps).round());

const _us = Duration(microseconds: 1);

/// Plays a synthetic video through `getLumaFrameStream`, like the native
/// decoder: frames of the requested range, in order, one event loop turn
/// apart, and an error for a range without frames.
class _FakeDecoder extends ProVideoEditor with MockPlatformInterfaceMixin {
  _FakeDecoder(this.frames);

  /// Every frame of the video.
  final List<Uint8List> frames;

  /// The `(startTime, endTime)` of every stream asked for.
  final List<(Duration?, Duration?)> requests = [];

  /// The task id of every stream asked for.
  final List<String> ids = [];

  /// Called when a stream is asked for, with its number, counted from one.
  void Function(int request)? onRequest;

  /// Called when a stream delivered its last frame, with its number.
  void Function(int request)? onRequestDone;

  final Set<String> _cancelled = {};
  bool _streaming = false;

  @override
  void initializeStream() {}

  @override
  Stream<LumaFrame> getLumaFrameStream(
    LumaFrameConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) async* {
    // Native refuses a task under an id still in use, and a stream left
    // early is torn down only after the consumer moved on.
    if (ids.contains(value.id)) {
      throw PlatformException(code: 'TASK_ALREADY_RUNNING');
    }
    ids.add(value.id);
    requests.add((value.startTime, value.endTime));
    final request = requests.length;
    _streaming = true;
    onRequest?.call(request);
    final start = value.startTime ?? Duration.zero;
    final end = value.endTime ?? _frameTime(frames.length);
    final inRange = [
      for (var i = 0; i < frames.length; i++)
        if (_frameTime(i) >= start && _frameTime(i) < end) i,
    ];
    if (inRange.isEmpty) {
      _streaming = false;
      throw PlatformException(
        code: 'FRAME_STREAM_ERROR',
        message: 'The frame range holds no frames',
      );
    }
    try {
      for (var k = 0; k < inRange.length; k++) {
        await Future<void>(() {});
        if (_cancelled.remove(value.id)) {
          throw const RenderCanceledException();
        }
        final i = inRange[k];
        yield LumaFrame(
          time: _frameTime(i),
          width: _width,
          height: _height,
          bytes: frames[i],
          progress: (k + 1) / inRange.length,
        );
      }
    } finally {
      _streaming = false;
    }
    onRequestDone?.call(request);
  }

  @override
  Future<void> cancel(String taskId) async {
    if (!_streaming) {
      throw PlatformException(code: 'TASK_NOT_FOUND');
    }
    _cancelled.add(taskId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final scene = SyntheticScene(width: _width, height: _height);
  final video = EditorVideo.file('/tmp/clip.mp4');
  late ProVideoEditor original;

  setUp(() => original = ProVideoEditor.instance);
  tearDown(() => ProVideoEditor.instance = original);

  /// A video of [count] frames with the object at [pose] in each.
  _FakeDecoder decoder(int count, ScenePose Function(int frame) pose) {
    final fake = _FakeDecoder([
      for (var i = 0; i < count; i++) scene.render(pose(i)),
    ]);
    ProVideoEditor.instance = fake;
    return fake;
  }

  Rect regionAround(ScenePose pose) => Rect.fromCenter(
    center: Offset(pose.x / _width, pose.y / _height),
    width: scene.objectWidth / _width,
    height: scene.objectHeight / _height,
  );

  ScenePose drift(int i) => ScenePose(50 + 1.2 * i, 50 + 0.3 * i);

  group('trackVideo', () {
    test(
      'follows the object forward and backward from the marked frame',
      () async {
        final fake = decoder(60, drift);
        final progress = <double>[];
        final track = await VideoObjectTracker.trackVideo(
          video,
          region: regionAround(drift(30)),
          anchorTime: _frameTime(30),
          endTime: _frameTime(60),
          id: 'track-1',
          onProgress: progress.add,
        );

        expect(track.anchorTime, _frameTime(30));
        expect(track.reachedStart, isTrue);
        expect(track.reachedEnd, isTrue);
        expect(track.samples, hasLength(60));
        for (var i = 0; i < 60; i++) {
          final sample = track.samples[i];
          expect(sample.time, _frameTime(i));
          expect(
            sample.center.dx * _width,
            closeTo(drift(i).x, 0.75),
            reason: '$i',
          );
          expect(
            sample.center.dy * _height,
            closeTo(drift(i).y, 0.75),
            reason: '$i',
          );
        }
        expect(track.anchor!.scale, 1);

        // Forward from the marked frame first, then the frames before it,
        // up to and including the marked one.
        expect(fake.requests.first, (_frameTime(30), _frameTime(60)));
        expect(fake.requests.last.$2, _frameTime(30) + _us);
        expect(progress, orderedEquals([...progress]..sort()));
        expect(progress.last, 1);
      },
    );

    test(
      'reads the frames before the marked one in pieces from the end',
      () async {
        final fake = decoder(150, drift);
        final track = await VideoObjectTracker.trackVideo(
          video,
          region: regionAround(drift(135)),
          anchorTime: _frameTime(135),
          endTime: _frameTime(150),
          smoothing: Duration.zero,
        );

        expect(track.samples, hasLength(150));
        expect(track.samples.first.center.dx * _width, closeTo(drift(0).x, 1));
        // Each piece reaches up to the earliest frame read before it.
        expect(fake.requests, [
          (_frameTime(135), _frameTime(150)),
          (_frameTime(75), _frameTime(135) + _us),
          (_frameTime(15), _frameTime(75) + _us),
          (Duration.zero, _frameTime(15) + _us),
        ]);
      },
    );

    test('stays inside the range it is given', () async {
      decoder(60, drift);
      final track = await VideoObjectTracker.trackVideo(
        video,
        region: regionAround(drift(30)),
        anchorTime: _frameTime(30),
        startTime: _frameTime(20),
        endTime: _frameTime(40),
      );
      expect(track.samples.first.time, _frameTime(20));
      expect(track.samples.last.time, _frameTime(39));
    });

    test(
      'marks the last frame before the anchor when none follows it',
      () async {
        decoder(30, drift);
        final track = await VideoObjectTracker.trackVideo(
          video,
          region: regionAround(drift(29)),
          anchorTime: _frameTime(30),
          endTime: _frameTime(30),
        );
        expect(track.anchorTime, _frameTime(29));
        expect(track.samples, hasLength(30));
        expect(
          track.samples.first.center.dx * _width,
          closeTo(drift(0).x, 0.75),
        );
      },
    );

    test('marks the first frame of a range that starts between two', () async {
      // Nothing lies between the start and the first frame, which the
      // decoder refuses as a range of its own.
      final fake = decoder(30, drift);
      final start = _frameTime(10) - const Duration(milliseconds: 10);
      final track = await VideoObjectTracker.trackVideo(
        video,
        region: regionAround(drift(10)),
        anchorTime: start,
        startTime: start,
        endTime: _frameTime(30),
      );
      expect(track.anchorTime, _frameTime(10));
      expect(track.samples.first.time, _frameTime(10));
      expect(track.samples, hasLength(20));
      expect(fake.requests.last, (start, _frameTime(10) + _us));
    });

    test('marks the last frame when the mark lies past it', () async {
      // A player paused at the end reports the video's duration.
      decoder(30, drift);
      final track = await VideoObjectTracker.trackVideo(
        video,
        region: regionAround(drift(29)),
        anchorTime: _frameTime(30),
      );
      expect(track.anchorTime, _frameTime(29));
      expect(track.samples, hasLength(30));
    });

    test('takes a mark outside the range on its nearest end', () async {
      decoder(60, drift);
      final track = await VideoObjectTracker.trackVideo(
        video,
        region: regionAround(drift(20)),
        anchorTime: _frameTime(5),
        startTime: _frameTime(20),
        endTime: _frameTime(40),
      );
      expect(track.anchorTime, _frameTime(20));
      expect(track.samples.first.time, _frameTime(20));
      expect(track.samples.last.time, _frameTime(39));
    });

    test('says where it lost the object', () async {
      // The object comes in from the left and leaves on the right.
      ScenePose cross(int i) => ScenePose(-20 + 9 * i, 68);
      decoder(32, cross);
      final track = await VideoObjectTracker.trackVideo(
        video,
        region: regionAround(cross(12)),
        anchorTime: _frameTime(12),
        endTime: _frameTime(32),
        smoothing: Duration.zero,
      );
      expect(track.reachedStart, isFalse);
      expect(track.reachedEnd, isFalse);
      expect(track.samples.first.time, greaterThan(Duration.zero));
      expect(track.samples.last.time, lessThan(_frameTime(29)));
      for (final sample in track.samples) {
        final i = (sample.time.inMicroseconds * _fps / 1e6).round();
        expect(sample.center.dx * _width, closeTo(cross(i).x, 1), reason: '$i');
      }
    });

    test('reads every stream under its own task id', () async {
      // The object leaves on the right, so the forward stream is left early
      // and the backward pass starts while it is still being torn down.
      ScenePose leave(int i) => ScenePose(150 + 9 * i, 68);
      final fake = decoder(30, leave);
      final track = await VideoObjectTracker.trackVideo(
        video,
        region: regionAround(leave(5)),
        anchorTime: _frameTime(5),
        endTime: _frameTime(30),
        id: 'track-ids',
      );
      expect(track.reachedEnd, isFalse);
      expect(fake.ids.toSet(), hasLength(fake.ids.length));
      expect(fake.ids, everyElement(startsWith('track-ids')));
    });

    test('gives only the marked frame for a region without detail', () async {
      final flat = Uint8List(_width * _height)
        ..fillRange(0, _width * _height, 90);
      ProVideoEditor.instance = _FakeDecoder(List.filled(20, flat));
      final track = await VideoObjectTracker.trackVideo(
        video,
        region: const Rect.fromLTWH(0.4, 0.4, 0.2, 0.2),
        anchorTime: _frameTime(10),
        endTime: _frameTime(20),
      );
      expect(track.isFollowed, isFalse);
      expect(track.reachedStart, isFalse);
      expect(track.reachedEnd, isFalse);
    });

    test('stops when cancelled while frames decode', () async {
      decoder(60, drift).onRequest = (request) {
        if (request == 2) unawaited(VideoObjectTracker.cancel('track-2'));
      };
      await expectLater(
        VideoObjectTracker.trackVideo(
          video,
          region: regionAround(drift(30)),
          anchorTime: _frameTime(30),
          endTime: _frameTime(60),
          id: 'track-2',
        ),
        throwsA(isA<RenderCanceledException>()),
      );
    });

    test('stops before the next piece when cancelled between two', () async {
      final fake = decoder(150, drift)
        ..onRequestDone = (request) {
          if (request == 2) unawaited(VideoObjectTracker.cancel('track-3'));
        };
      await expectLater(
        VideoObjectTracker.trackVideo(
          video,
          region: regionAround(drift(135)),
          anchorTime: _frameTime(135),
          endTime: _frameTime(150),
          id: 'track-3',
        ),
        throwsA(isA<RenderCanceledException>()),
      );
      expect(fake.requests, hasLength(2));
    });

    test('does nothing when cancelling a call that does not run', () async {
      ProVideoEditor.instance = _FakeDecoder(const []);
      await expectLater(VideoObjectTracker.cancel('nothing'), completes);
    });
  });
}
