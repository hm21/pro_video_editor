import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/platform/native_method_channel.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('pro_video_editor');
  const streamChannel = EventChannel('pro_video_editor_thumbnail_stream');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('getLumaFrameStream', () {
    late MethodChannelProVideoEditor platform;
    late List<MethodCall> calls;
    late Completer<MockStreamHandlerEventSink> sinkReady;

    setUp(() {
      platform = MethodChannelProVideoEditor();
      calls = [];
      sinkReady = Completer<MockStreamHandlerEventSink>();
      messenger
        ..setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          return null;
        })
        ..setMockStreamHandler(
          streamChannel,
          MockStreamHandler.inline(
            onListen: (_, sink) => sinkReady.complete(sink),
          ),
        );
    });

    tearDown(() {
      messenger
        ..setMockMethodCallHandler(methodChannel, null)
        ..setMockStreamHandler(streamChannel, null);
    });

    Future<MockStreamHandlerEventSink> awaitStart() async {
      final sink = await sinkReady.future;
      await pumpEventQueue();
      return sink;
    }

    test('starts the native task with the range and frame rate', () async {
      final done = platform
          .getLumaFrameStream(
            LumaFrameConfigs(
              id: 'luma-1',
              video: EditorVideo.file('/tmp/clip.mp4'),
              outputSize: const Size(320, 320),
              startTime: const Duration(milliseconds: 1500),
              endTime: const Duration(seconds: 4),
              maxFrameRate: 30,
            ),
          )
          .drain<void>();
      final sink = await awaitStart();

      final args =
          calls.singleWhere((c) => c.method == 'startFrameStream').arguments
              as Map;
      expect(args['id'], 'luma-1');
      expect(args['inputPath'], '/tmp/clip.mp4');
      expect(args['outputWidth'], 320);
      expect(args['outputHeight'], 320);
      expect(args['startUs'], 1500000);
      expect(args['endUs'], 4000000);
      expect(args['maxFrameRate'], 30);

      sink.success({'id': 'luma-1', 'done': true});
      await done;
    });

    test('delivers its frames with their timestamps and sizes', () async {
      final frames = <LumaFrame>[];
      final done = Completer<void>();
      platform
          .getLumaFrameStream(
            LumaFrameConfigs(
              id: 'luma-2',
              video: EditorVideo.file('/tmp/clip.mp4'),
              outputSize: const Size(4, 4),
            ),
          )
          .listen(frames.add, onDone: done.complete);
      final sink = await awaitStart();

      sink
        ..success({
          'id': 'luma-2',
          'ptsUs': 33367,
          'width': 2,
          'height': 3,
          'bytes': Uint8List.fromList([1, 2, 3, 4, 5, 6]),
          'progress': 0.5,
        })
        ..success({
          'id': 'other-task',
          'ptsUs': 0,
          'width': 1,
          'height': 1,
          'bytes': Uint8List.fromList([9]),
          'progress': 1.0,
        })
        ..success({'id': 'luma-2', 'done': true});
      await done.future;

      expect(frames, hasLength(1));
      expect(frames.single.time, const Duration(microseconds: 33367));
      expect(frames.single.width, 2);
      expect(frames.single.height, 3);
      expect(frames.single.bytes, [1, 2, 3, 4, 5, 6]);
      expect(frames.single.progress, 0.5);
    });

    test('reports a native failure and closes', () async {
      final errors = <Object>[];
      final done = Completer<void>();
      platform
          .getLumaFrameStream(
            LumaFrameConfigs(
              id: 'luma-3',
              video: EditorVideo.file('/tmp/clip.mp4'),
              outputSize: const Size(4, 4),
            ),
          )
          .listen((_) {}, onError: errors.add, onDone: done.complete);
      final sink = await awaitStart();

      sink.success({'id': 'luma-3', 'error': 'no video track'});
      await done.future;

      expect(
        errors.single,
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'FRAME_STREAM_ERROR')
            .having((e) => e.message, 'message', 'no video track'),
      );
    });
  });
}
