import 'dart:async';
import 'dart:io';

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

  ThumbnailConfigs configs({String id = 'strip-1', int? maxParallelDecoders}) {
    return ThumbnailConfigs(
      id: id,
      video: EditorVideo.file('/tmp/clip.mp4'),
      outputSize: const Size(48, 54),
      timestamps: const [
        Duration(milliseconds: 500),
        Duration(milliseconds: 1500),
        Duration(milliseconds: 2500),
      ],
      maxParallelDecoders: maxParallelDecoders,
    );
  }

  group('getThumbnailStream', () {
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
      // The start request is dispatched right after the subscription.
      await pumpEventQueue();
      return sink;
    }

    /// Listens to [stream] and completes when it closes. Unlike
    /// `asFuture`, an error does not end the wait, so a test can assert on
    /// the error *and* on the stream closing afterwards.
    Future<void> drain(
      Stream<ThumbnailFrame> stream, {
      List<ThumbnailFrame>? into,
      List<Object>? errors,
    }) {
      final done = Completer<void>();
      stream.listen(
        (frame) => into?.add(frame),
        onError: (Object error) => errors?.add(error),
        onDone: done.complete,
      );
      return done.future;
    }

    test('starts the native task with the configuration', () async {
      final events = <ThumbnailFrame>[];
      final done = drain(
        platform.getThumbnailStream(configs(maxParallelDecoders: 1)),
        into: events,
      );
      final sink = await awaitStart();

      final start = calls.singleWhere(
        (c) => c.method == 'startThumbnailStream',
      );
      final args = start.arguments as Map;
      expect(args['id'], 'strip-1');
      expect(args['inputPath'], '/tmp/clip.mp4');
      expect(args['timestamps'], [500000, 1500000, 2500000]);
      expect(args['maxParallelDecoders'], 1);

      sink.success({'id': 'strip-1', 'done': true});
      await done;
      expect(events, isEmpty);
    });

    test('delivers frames for its own id and closes on done', () async {
      final events = <ThumbnailFrame>[];
      final done = drain(platform.getThumbnailStream(configs()), into: events);
      final sink = await awaitStart();

      sink
        ..success({
          'id': 'strip-1',
          'indices': [1],
          'bytes': Uint8List.fromList([1, 2, 3]),
          'progress': 1 / 3,
        })
        ..success({
          'id': 'other-task',
          'indices': [0],
          'bytes': Uint8List.fromList([9]),
          'progress': 0.5,
        })
        ..success({
          'id': 'strip-1',
          'indices': [0, 2],
          'bytes': Uint8List.fromList([4]),
          'progress': 1.0,
        })
        ..success({'id': 'strip-1', 'done': true});
      await done;

      expect(events, hasLength(2));
      expect(events[0].indices, [1]);
      expect(events[0].bytes, [1, 2, 3]);
      expect(events[0].progress, closeTo(1 / 3, 1e-9));
      expect(events[1].indices, [0, 2]);
      expect(events[1].bytes, [4]);
      expect(events[1].progress, 1.0);
      // A finished stream sends no cancel for a task that no longer exists.
      expect(calls.where((c) => c.method == 'cancelTask'), isEmpty);
    });

    test('maps a CANCELED error event to RenderCanceledException', () async {
      final errors = <Object>[];
      final done = drain(
        platform.getThumbnailStream(configs()),
        errors: errors,
      );
      final sink = await awaitStart();

      sink.success({
        'id': 'strip-1',
        'error': 'Thumbnail task was canceled',
        'errorCode': 'CANCELED',
      });
      await done;

      expect(errors, [isA<RenderCanceledException>()]);
    });

    test('maps any other error event to a PlatformException', () async {
      final errors = <Object>[];
      final done = drain(
        platform.getThumbnailStream(configs()),
        errors: errors,
      );
      final sink = await awaitStart();

      sink.success({
        'id': 'strip-1',
        'error': 'No frames could be decoded',
        'errorCode': 'THUMBNAIL_ERROR',
      });
      await done;

      expect(errors, hasLength(1));
      final error = errors.single as PlatformException;
      expect(error.code, 'THUMBNAIL_ERROR');
      expect(error.message, 'No frames could be decoded');
    });

    test('cancelling the subscription cancels the native task', () async {
      final subscription = platform
          .getThumbnailStream(configs())
          .listen((_) {});
      await awaitStart();

      await subscription.cancel();
      await pumpEventQueue();

      final cancel = calls.singleWhere((c) => c.method == 'cancelTask');
      expect((cancel.arguments as Map)['id'], 'strip-1');
    });

    test('cancel during the start sends a single cancelTask', () async {
      final started = Completer<void>();
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        calls.add(call);
        if (call.method == 'startThumbnailStream') await started.future;
        return null;
      });
      final subscription = platform
          .getThumbnailStream(configs())
          .listen((_) {});
      await awaitStart();
      expect(calls.map((c) => c.method), ['startThumbnailStream']);

      await subscription.cancel();
      started.complete();
      await pumpEventQueue();

      // The consumer's cancel follows the start on the same channel, so
      // native finds the task; a follow-up cancel once the start returns
      // would only be answered with TASK_NOT_FOUND.
      expect(calls.map((c) => c.method), [
        'startThumbnailStream',
        'cancelTask',
      ]);
    });

    test('events that arrive after a consumer cancel are dropped', () async {
      final events = <ThumbnailFrame>[];
      final subscription = platform
          .getThumbnailStream(configs())
          .listen(events.add);
      final sink = await awaitStart();

      sink.success({
        'id': 'strip-1',
        'indices': [0],
        'bytes': Uint8List.fromList([1]),
        'progress': 1 / 3,
      });
      await pumpEventQueue();
      await subscription.cancel();

      // The decoder's last in-flight frame and its CANCELED report still
      // arrive; neither may reach the closed controller.
      sink
        ..success({
          'id': 'strip-1',
          'indices': [1],
          'bytes': Uint8List.fromList([2]),
          'progress': 2 / 3,
        })
        ..success({
          'id': 'strip-1',
          'error': 'Thumbnail task was canceled',
          'errorCode': 'CANCELED',
        });
      await pumpEventQueue();

      expect(events.map((f) => f.indices), [
        [0],
      ]);
      expect(calls.where((c) => c.method == 'cancelTask'), hasLength(1));
    });

    test('a cancel before dispatch never starts the native task', () async {
      // Park the start on its first await: an asset source is copied to a
      // temp file first, and a path_provider that never answers keeps the
      // start there until the subscription is gone.
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(
        pathProvider,
        (_) => Completer<Object?>().future,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
      final blocked = ThumbnailConfigs(
        id: 'blocked',
        video: EditorVideo.asset('assets/clip.mp4'),
        outputSize: const Size(48, 54),
        timestamps: const [Duration(seconds: 1)],
      );

      final subscription = platform.getThumbnailStream(blocked).listen((_) {});
      await pumpEventQueue();
      await subscription.cancel();
      await pumpEventQueue();

      expect(calls.where((c) => c.method == 'startThumbnailStream'), isEmpty);
      // The pre-dispatch cancel is handled locally, so native is never asked
      // to cancel a task it does not know.
      expect(calls.where((c) => c.method == 'cancelTask'), isEmpty);
    });

    test('cancel() before dispatch surfaces RenderCanceledException', () async {
      // Hold the start on its first await (the temp directory lookup a
      // memory source needs before it is written to disk), cancel the task
      // while it waits there, then let the start proceed to its handoff.
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final tempDir = Completer<String>();
      messenger.setMockMethodCallHandler(pathProvider, (_) => tempDir.future);
      addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
      final dir = await Directory.systemTemp.createTemp('pve_thumbnail_stream');
      addTearDown(() => dir.delete(recursive: true));
      final blocked = ThumbnailConfigs(
        id: 'blocked',
        video: EditorVideo.memory(Uint8List.fromList([0, 1, 2])),
        outputSize: const Size(48, 54),
        timestamps: const [Duration(seconds: 1)],
      );

      final errors = <Object>[];
      final done = drain(platform.getThumbnailStream(blocked), errors: errors);
      await pumpEventQueue();
      await platform.cancel('blocked');
      tempDir.complete(dir.path);
      await done;

      // The still-listening consumer is told, and native never saw the task.
      expect(errors, [isA<RenderCanceledException>()]);
      expect(calls.where((c) => c.method == 'startThumbnailStream'), isEmpty);
      expect(calls.where((c) => c.method == 'cancelTask'), isEmpty);
    });

    test('a failed start surfaces as a stream error', () async {
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        calls.add(call);
        if (call.method == 'startThumbnailStream') {
          throw PlatformException(code: 'INVALID_ARGUMENTS', message: 'nope');
        }
        return null;
      });
      final errors = <Object>[];
      await drain(platform.getThumbnailStream(configs()), errors: errors);

      expect(errors, [isA<PlatformException>()]);
      expect((errors.single as PlatformException).code, 'INVALID_ARGUMENTS');
    });
  });

  group('ThumbnailFrame', () {
    test('parses a platform event map', () {
      final frame = ThumbnailFrame.fromMap({
        'id': 'x',
        'indices': [3, 4],
        'bytes': Uint8List.fromList([7, 8]),
        'progress': 0.25,
      });

      expect(frame.indices, [3, 4]);
      expect(frame.bytes, [7, 8]);
      expect(frame.progress, 0.25);
      expect(frame.toString(), contains('indices: [3, 4]'));
    });

    test('rejects a map without bytes', () {
      expect(
        () => ThumbnailFrame.fromMap({
          'indices': [0],
          'progress': 1.0,
        }),
        throwsArgumentError,
      );
    });
  });

  group('ThumbnailConfigs.maxParallelDecoders', () {
    test('is omitted from the map when unset', () {
      expect(configs().toMap().containsKey('maxParallelDecoders'), isFalse);
    });

    test('is sent when set', () {
      expect(configs(maxParallelDecoders: 2).toMap()['maxParallelDecoders'], 2);
    });

    test('rejects values below one', () {
      expect(() => configs(maxParallelDecoders: 0), throwsAssertionError);
    });
  });
}
