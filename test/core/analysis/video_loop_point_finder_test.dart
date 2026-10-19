import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

import 'synthetic_scene.dart';

const _width = 96;
const _height = 54;
const _fps = 30;

/// How many frames one turn of the synthetic motion takes.
const _period = 40;

Duration _frameTime(int frame) =>
    Duration(microseconds: (frame * 1e6 / _fps).round());

/// [frame] at twice its width and height, each pixel repeated.
Uint8List _doubled(Uint8List frame) {
  final out = Uint8List(_width * _height * 4);
  for (var y = 0; y < _height * 2; y++) {
    for (var x = 0; x < _width * 2; x++) {
      out[y * _width * 2 + x] = frame[(y ~/ 2) * _width + x ~/ 2];
    }
  }
  return out;
}

/// Plays a synthetic video through `getLumaFrameStream`, like the native
/// decoder: frames of the requested range, in order, one event loop turn
/// apart, and an error for a range without frames. Like native, it refuses
/// a task id it has seen before.
class _FakeDecoder extends ProVideoEditor with MockPlatformInterfaceMixin {
  _FakeDecoder(
    this.frames, {
    this.startVideo,
    this.startFrames,
    this.fps = _fps,
  });

  /// Every frame of the video.
  final List<Uint8List> frames;

  /// A second video, played with [startFrames] instead.
  final EditorVideo? startVideo;

  /// Every frame of [startVideo].
  final List<Uint8List>? startFrames;

  /// The frame rate of both videos.
  final int fps;

  /// The video of every stream asked for.
  final List<EditorVideo> videos = [];

  /// The `(startTime, endTime)` of every stream asked for.
  final List<(Duration?, Duration?)> requests = [];

  /// The task id of every stream asked for.
  final List<String> ids = [];

  /// The times of the frames every stream delivered.
  final List<List<Duration>> delivered = [];

  /// Called when a stream delivered a frame, with the stream's number,
  /// counted from one.
  void Function(int request)? onFrame;

  final Set<String> _cancelled = {};
  final Set<String> _streaming = {};

  Duration _time(int frame) =>
      Duration(microseconds: (frame * 1e6 / fps).round());

  @override
  void initializeStream() {}

  @override
  Stream<LumaFrame> getLumaFrameStream(
    LumaFrameConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) async* {
    if (ids.contains(value.id)) {
      throw PlatformException(code: 'TASK_ALREADY_RUNNING');
    }
    ids.add(value.id);
    videos.add(value.video);
    requests.add((value.startTime, value.endTime));
    final times = <Duration>[];
    delivered.add(times);
    final request = requests.length;
    final frames = value.video == startVideo ? startFrames! : this.frames;
    final start = value.startTime ?? Duration.zero;
    final end = value.endTime ?? _time(frames.length);
    final inRange = [
      for (var i = 0; i < frames.length; i++)
        if (_time(i) >= start && _time(i) < end) i,
    ];
    if (inRange.isEmpty) {
      throw PlatformException(
        code: 'FRAME_STREAM_ERROR',
        message: 'The frame range holds no frames',
      );
    }
    _streaming.add(value.id);
    try {
      for (var k = 0; k < inRange.length; k++) {
        await Future<void>(() {});
        if (_cancelled.remove(value.id)) {
          throw const RenderCanceledException();
        }
        final i = inRange[k];
        times.add(_time(i));
        yield LumaFrame(
          time: _time(i),
          width: _width,
          height: _height,
          bytes: frames[i],
          progress: (k + 1) / inRange.length,
        );
        onFrame?.call(request);
      }
    } finally {
      _streaming.remove(value.id);
    }
  }

  @override
  Future<void> cancel(String taskId) async {
    if (!_streaming.contains(taskId)) {
      throw PlatformException(code: 'TASK_NOT_FOUND');
    }
    _cancelled.add(taskId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final scene = SyntheticScene(
    width: _width,
    height: _height,
    objectWidth: 18,
    objectHeight: 14,
  );

  /// Circles around the middle once every [_period] frames.
  ScenePose circle(num frame) {
    final angle = 2 * pi * frame / _period;
    return ScenePose(48 + 24 * cos(angle), 27 + 12 * sin(angle));
  }

  /// Swings left and right once every [_period] frames: in the middle at
  /// frames 0 and 20 alike, but moving the other way.
  ScenePose pendulum(int frame) =>
      ScenePose(48 + 28 * sin(2 * pi * frame / _period), 27);

  List<Uint8List> render(int count, ScenePose Function(int frame) pose) => [
    for (var i = 0; i < count; i++) scene.render(pose(i)),
  ];

  /// A finder fed [frames] [headFrom]..[headTo] as the head and
  /// [tailFrom]..[tailTo] as the tail, both ends included.
  VideoLoopPointFinder finderFor(
    List<Uint8List> frames, {
    required int headFrom,
    required int headTo,
    required int tailFrom,
    required int tailTo,
  }) {
    final finder = VideoLoopPointFinder(width: _width, height: _height);
    for (var i = headFrom; i <= headTo; i++) {
      finder.addHeadFrame(frames[i], _frameTime(i));
    }
    for (var i = tailFrom; i <= tailTo; i++) {
      finder.addTailFrame(frames[i], _frameTime(i));
    }
    return finder;
  }

  group(VideoLoopPointFinder, () {
    group('find', () {
      test('cuts right before the frame where the motion is back at the '
          'start', () {
        final frames = render(64, circle);
        final point =
            finderFor(
              frames,
              headFrom: 0,
              headTo: 4,
              tailFrom: 20,
              tailTo: 63,
            ).find(
              start: Duration.zero,
              end: _frameTime(64),
              endFrom: _frameTime(22),
              endTo: _frameTime(63),
            );

        expect(point.start, Duration.zero);
        expect(point.end, _frameTime(_period));
        expect(point.difference, lessThan(0.001));
        expect(point.currentDifference, greaterThan(point.difference + 0.02));
      });

      test('does not take a match that moves the other way, even when it is '
          'closer to the current end', () {
        // The pendulum passes the middle at frames 20, 40 and 60, but only at
        // 40 swinging the same way as at frame 0.
        final frames = render(64, pendulum);
        final point =
            finderFor(
              frames,
              headFrom: 0,
              headTo: 4,
              tailFrom: 8,
              tailTo: 63,
            ).find(
              start: Duration.zero,
              end: _frameTime(64),
              endFrom: _frameTime(10),
              endTo: _frameTime(63),
            );

        expect(point.end, _frameTime(_period));
      });

      test('brings back footage trimmed off past the current end', () {
        final frames = render(64, circle);
        final point =
            finderFor(
              frames,
              headFrom: 0,
              headTo: 4,
              tailFrom: 20,
              tailTo: 63,
            ).find(
              start: Duration.zero,
              end: _frameTime(30),
              endFrom: _frameTime(22),
              endTo: _frameTime(63),
            );

        expect(point.end, _frameTime(_period));
        expect(point.currentDifference, greaterThan(point.difference + 0.02));
      });

      test('does not slip a frame towards the current end in slow '
          'motion', () {
        // Slow enough that one frame changes the picture only a little.
        const slowPeriod = 160;
        final frames = render(170, (i) => circle(i * _period / slowPeriod));
        final point =
            finderFor(
              frames,
              headFrom: 0,
              headTo: 4,
              tailFrom: 140,
              tailTo: 169,
            ).find(
              start: Duration.zero,
              end: _frameTime(slowPeriod + 4),
              endFrom: _frameTime(142),
              endTo: _frameTime(169),
            );

        expect(point.end, _frameTime(slowPeriod));
      });

      test('keeps the current end when every cut matches about equally', () {
        final still = scene.render(ScenePose(48, 27));
        final frames = List.filled(64, still);
        final point =
            finderFor(
              frames,
              headFrom: 0,
              headTo: 4,
              tailFrom: 20,
              tailTo: 63,
            ).find(
              start: Duration.zero,
              end: _frameTime(50),
              endFrom: _frameTime(22),
              endTo: _frameTime(63),
            );

        expect(point.end, _frameTime(50));
        expect(point.difference, 0);
        expect(point.currentDifference, 0);
      });

      test('compares the last frame with the first when the video has no '
          'frame at the current end', () {
        final frames = render(64, circle);
        final finder = finderFor(
          frames,
          headFrom: 0,
          headTo: 4,
          tailFrom: 20,
          tailTo: 63,
        );
        final point = finder.find(
          start: Duration.zero,
          end: _frameTime(64),
          endFrom: _frameTime(22),
          endTo: _frameTime(63),
        );
        final lastAgainstFirst =
            finderFor(
              [frames[0], frames[63]],
              headFrom: 0,
              headTo: 0,
              tailFrom: 1,
              tailTo: 1,
            ).find(
              start: Duration.zero,
              end: _frameTime(1),
              endFrom: _frameTime(1),
              endTo: _frameTime(1),
            );

        expect(point.currentDifference, lastAgainstFirst.difference);
      });

      test('matches the start of another video', () {
        // The first video starts where the circling one is at frame 10.
        final frames = render(64, circle);
        final finder = VideoLoopPointFinder(width: _width, height: _height);
        for (var i = 0; i <= 4; i++) {
          finder.addHeadFrame(scene.render(circle(i + 10)), _frameTime(i));
        }
        for (var i = 20; i <= 63; i++) {
          finder.addTailFrame(frames[i], _frameTime(i));
        }

        final point = finder.find(
          start: Duration.zero,
          end: _frameTime(64),
          endFrom: _frameTime(22),
          endTo: _frameTime(63),
          startsInSameVideo: false,
        );

        expect(point.end, _frameTime(50));
      });

      test('compares frames of different sizes', () {
        final frames = render(64, circle);
        final finder = VideoLoopPointFinder(width: _width, height: _height);
        for (var i = 0; i <= 4; i++) {
          finder.addHeadFrame(
            _doubled(frames[i]),
            _frameTime(i),
            width: _width * 2,
            height: _height * 2,
          );
        }
        for (var i = 20; i <= 63; i++) {
          finder.addTailFrame(frames[i], _frameTime(i));
        }

        final point = finder.find(
          start: Duration.zero,
          end: _frameTime(64),
          endFrom: _frameTime(22),
          endTo: _frameTime(63),
        );

        expect(point.end, _frameTime(_period));
        expect(point.difference, lessThan(0.001));
      });

      test('moves the start too when given a range for it', () {
        // Frame 55 shows the motion where it is at frame 15.
        final frames = render(64, circle);
        final point =
            finderFor(
              frames,
              headFrom: 0,
              headTo: 24,
              tailFrom: 50,
              tailTo: 60,
            ).find(
              start: Duration.zero,
              end: _frameTime(55),
              endFrom: _frameTime(55),
              endTo: _frameTime(55),
              startFrom: Duration.zero,
              startTo: _frameTime(20),
            );

        expect(point.start, _frameTime(15));
        expect(point.end, _frameTime(55));
      });

      test('throws when the end range holds no frames', () {
        final frames = render(64, circle);
        final finder = finderFor(
          frames,
          headFrom: 0,
          headTo: 4,
          tailFrom: 20,
          tailTo: 40,
        );

        expect(
          () => finder.find(
            start: Duration.zero,
            end: _frameTime(64),
            endFrom: _frameTime(50),
            endTo: _frameTime(63),
          ),
          throwsStateError,
        );
      });

      test('throws for an end before the start', () {
        final finder = VideoLoopPointFinder(width: _width, height: _height);

        expect(
          () => finder.find(
            start: _frameTime(10),
            end: _frameTime(5),
            endFrom: _frameTime(5),
            endTo: _frameTime(8),
          ),
          throwsArgumentError,
        );
      });
    });

    group('addHeadFrame', () {
      test('throws for a frame out of order', () {
        final finder = VideoLoopPointFinder(width: _width, height: _height)
          ..addHeadFrame(Uint8List(_width * _height), _frameTime(2));

        expect(
          () => finder.addHeadFrame(Uint8List(_width * _height), _frameTime(1)),
          throwsArgumentError,
        );
      });
    });

    group('findLoopPoint', () {
      final video = EditorVideo.file('/tmp/clip.mp4');
      late ProVideoEditor original;

      setUp(() => original = ProVideoEditor.instance);
      tearDown(() => ProVideoEditor.instance = original);

      _FakeDecoder decoder(int count, ScenePose Function(int) pose) {
        final fake = _FakeDecoder(render(count, pose));
        ProVideoEditor.instance = fake;
        return fake;
      }

      test('reads the head and the tail and finds the cut', () async {
        final fake = decoder(64, circle);
        final progress = <double>[];

        final point = await VideoLoopPointFinder.findLoopPoint(
          video,
          start: Duration.zero,
          end: _frameTime(64),
          endFrom: _frameTime(22),
          endTo: _frameTime(64),
          id: 'loop',
          onProgress: progress.add,
        );

        expect(point.end, _frameTime(_period));
        expect(fake.ids, [startsWith('loop-head-'), startsWith('loop-tail-')]);
        expect(fake.requests, [
          (Duration.zero, const Duration(milliseconds: 250)),
          (
            _frameTime(22) - const Duration(milliseconds: 250),
            _frameTime(64) + const Duration(milliseconds: 250),
          ),
        ]);
        expect(progress.last, 1);
        expect(progress, orderedEquals([...progress]..sort()));
      });

      test('reads the start from startVideo', () async {
        final startVideo = EditorVideo.file('/tmp/first.mp4');
        final fake = _FakeDecoder(
          render(64, circle),
          startVideo: startVideo,
          startFrames: render(8, (i) => circle(i + 10)),
        );
        ProVideoEditor.instance = fake;

        final point = await VideoLoopPointFinder.findLoopPoint(
          video,
          startVideo: startVideo,
          start: Duration.zero,
          end: _frameTime(64),
          endFrom: _frameTime(22),
          endTo: _frameTime(64),
        );

        expect(point.end, _frameTime(50));
        expect(fake.videos, [startVideo, video]);
      });

      test('fails with a RenderCanceledException when canceled', () async {
        decoder(64, circle).onFrame = (request) {
          if (request == 2) unawaited(VideoLoopPointFinder.cancel('loop'));
        };

        await expectLater(
          VideoLoopPointFinder.findLoopPoint(
            video,
            start: Duration.zero,
            end: _frameTime(64),
            endFrom: _frameTime(22),
            endTo: _frameTime(64),
            id: 'loop',
          ),
          throwsA(isA<RenderCanceledException>()),
        );
      });

      test('can run again under the same id once a call is canceled', () async {
        final fake = decoder(64, circle)
          ..onFrame = (request) {
            if (request == 1) unawaited(VideoLoopPointFinder.cancel('loop'));
          };
        await expectLater(
          VideoLoopPointFinder.findLoopPoint(
            video,
            start: Duration.zero,
            end: _frameTime(64),
            endFrom: _frameTime(22),
            endTo: _frameTime(64),
            id: 'loop',
          ),
          throwsA(isA<RenderCanceledException>()),
        );

        fake.onFrame = null;
        final point = await VideoLoopPointFinder.findLoopPoint(
          video,
          start: Duration.zero,
          end: _frameTime(64),
          endFrom: _frameTime(22),
          endTo: _frameTime(64),
          id: 'loop',
        );

        expect(point.end, _frameTime(_period));
      });

      Future<VideoLoopPoint> search() => VideoLoopPointFinder.findLoopPoint(
        video,
        start: Duration.zero,
        end: _frameTime(64),
        endFrom: _frameTime(22),
        endTo: _frameTime(64),
        id: 'loop',
      );

      test('runs a call started under the id of a canceled one that has not '
          'stopped yet', () async {
        final firstFrame = Completer<void>();
        decoder(64, circle).onFrame = (_) {
          if (!firstFrame.isCompleted) firstFrame.complete();
        };
        final first = expectLater(
          search(),
          throwsA(isA<RenderCanceledException>()),
        );
        await firstFrame.future;
        await VideoLoopPointFinder.cancel('loop');

        final second = search();
        await first;

        expect((await second).end, _frameTime(_period));
      });

      test('cancels a call started under the id of a canceled one after that '
          'one stopped', () async {
        final firstFrame = Completer<void>();
        decoder(64, circle).onFrame = (_) {
          if (!firstFrame.isCompleted) firstFrame.complete();
        };
        final first = expectLater(
          search(),
          throwsA(isA<RenderCanceledException>()),
        );
        await firstFrame.future;
        await VideoLoopPointFinder.cancel('loop');
        final second = expectLater(
          search(),
          throwsA(isA<RenderCanceledException>()),
        );
        await first;

        await VideoLoopPointFinder.cancel('loop');

        await second;
      });

      test(
        'reads two neighbours past either end of a range at 10 fps',
        () async {
          const fps = 10;
          Duration at(int frame) => Duration(milliseconds: frame * 1000 ~/ fps);
          final fake = _FakeDecoder(render(64, circle), fps: fps);
          ProVideoEditor.instance = fake;

          await VideoLoopPointFinder.findLoopPoint(
            video,
            start: Duration.zero,
            end: at(45),
            endFrom: at(30),
            endTo: at(50),
          );

          expect(fake.delivered[0].take(3), [at(0), at(1), at(2)]);
          expect(fake.delivered[1].first, at(28));
          expect(fake.delivered[1].last, at(52));
        },
      );
    });
  });
}
