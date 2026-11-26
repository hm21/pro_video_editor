import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/platform/native_method_channel.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('pro_video_editor');
  const streamChannel = EventChannel('pro_video_editor_waveform_stream');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  WaveformConfigs configs({String id = 'wave-1'}) => WaveformConfigs(
    id: id,
    video: EditorVideo.file('/tmp/song.m4a'),
    chunkSize: 2,
  );

  /// A chunk event of task [id] covering samples from [start] on, of a
  /// sound four samples long at one sample a second.
  Map<String, Object?> chunk(
    int start,
    List<double> left, {
    String id = 'wave-1',
    bool isComplete = false,
  }) => {
    'id': id,
    'leftChannel': Float32List.fromList(left),
    'startIndex': start,
    'progress': (start + left.length) / 4,
    'sampleRate': 44100,
    'totalDuration': 4000,
    'samplesPerSecond': 1,
    'isComplete': isComplete,
  };

  group('getWaveformStream', () {
    late MethodChannelProVideoEditor platform;
    late List<String> log;
    late List<MethodCall> calls;
    late MockStreamHandlerEventSink? sink;
    late List<Map<String, Object?>> sentOnStart;

    setUp(() {
      platform = MethodChannelProVideoEditor();
      log = [];
      calls = [];
      sink = null;
      sentOnStart = [];
      messenger
        ..setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          log.add(call.method);
          // Native decodes on its own thread and can send a chunk before
          // this call has returned.
          if (call.method == 'startWaveformStream') {
            for (final event in sentOnStart) {
              sink?.success(event);
            }
          }
          return null;
        })
        ..setMockStreamHandler(
          streamChannel,
          MockStreamHandler.inline(
            onListen: (_, events) {
              log.add('listen');
              sink = events;
            },
            onCancel: (_) => log.add('cancel'),
          ),
        );
    });

    tearDown(() {
      messenger
        ..setMockMethodCallHandler(methodChannel, null)
        ..setMockStreamHandler(streamChannel, null);
    });

    /// Listens to [stream] and completes when it closes, collecting what it
    /// sends.
    Future<void> drain(
      Stream<WaveformChunk> stream, {
      List<WaveformChunk>? into,
      List<Object>? errors,
    }) {
      final done = Completer<void>();
      stream.listen(
        (chunk) => into?.add(chunk),
        onError: (Object error) => errors?.add(error),
        onDone: done.complete,
      );
      return done.future;
    }

    test('listens for chunks before it starts the native task', () async {
      sentOnStart = [
        chunk(0, [0.1, 0.2]),
        chunk(2, [0.3], isComplete: true),
      ];
      final chunks = <WaveformChunk>[];

      await drain(platform.getWaveformStream(configs()), into: chunks);

      expect(log.take(2), ['listen', 'startWaveformStream']);
      expect(chunks.map((c) => c.startIndex), [0, 2]);
      expect(chunks.last.isComplete, isTrue);
    });

    test('starts the native task with the configuration', () async {
      sentOnStart = [chunk(0, const [], isComplete: true)];

      await drain(platform.getWaveformStream(configs()));

      final start = calls.singleWhere((c) => c.method == 'startWaveformStream');
      final args = start.arguments as Map;
      expect(args['id'], 'wave-1');
      expect(args['inputPath'], '/tmp/song.m4a');
      expect(args['chunkSize'], 2);
    });

    test('delivers chunks for its own id and closes on the last one', () async {
      sentOnStart = [
        chunk(0, [0.1, 0.2]),
        chunk(0, [0.9], id: 'other-task'),
        chunk(2, [0.3, 0.4], isComplete: true),
      ];
      final chunks = <WaveformChunk>[];

      await drain(platform.getWaveformStream(configs()), into: chunks);

      expect(chunks, hasLength(2));
      expect(chunks.first.leftChannel, [
        closeTo(0.1, 1e-6),
        closeTo(0.2, 1e-6),
      ]);
      // A finished stream sends no cancel for a task that no longer exists.
      expect(calls.where((c) => c.method == 'cancelTask'), isEmpty);
    });

    test('maps a NO_AUDIO error event to AudioNoTrackException', () async {
      sentOnStart = [
        {'id': 'wave-1', 'error': 'No audio track', 'errorCode': 'NO_AUDIO'},
      ];
      final errors = <Object>[];

      await drain(platform.getWaveformStream(configs()), errors: errors);

      expect(errors, [isA<AudioNoTrackException>()]);
    });

    test('maps a CANCELED error event to RenderCanceledException', () async {
      sentOnStart = [
        {'id': 'wave-1', 'error': 'Cancelled', 'errorCode': 'CANCELED'},
      ];
      final errors = <Object>[];

      await drain(platform.getWaveformStream(configs()), errors: errors);

      expect(errors, [isA<RenderCanceledException>()]);
    });

    test('maps any other error event to a PlatformException', () async {
      sentOnStart = [
        {
          'id': 'wave-1',
          'error': 'Decoder died',
          'errorCode': 'WAVEFORM_ERROR',
        },
      ];
      final errors = <Object>[];

      await drain(platform.getWaveformStream(configs()), errors: errors);

      expect(
        errors.single,
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'WAVEFORM_ERROR')
            .having((e) => e.message, 'message', 'Decoder died'),
      );
    });

    test('cancelling the subscription cancels the native task', () async {
      final subscription = platform.getWaveformStream(configs()).listen((_) {});
      await pumpEventQueue();

      await subscription.cancel();
      await pumpEventQueue();

      final cancel = calls.singleWhere((c) => c.method == 'cancelTask');
      expect((cancel.arguments as Map)['id'], 'wave-1');
    });

    // Each stream used to listen to the channel on its own, so the first to
    // finish told native to stop sending, and the other lost its chunks.
    test('a finished stream leaves another one receiving', () async {
      final first = <WaveformChunk>[];
      final second = <WaveformChunk>[];
      final firstDone = drain(
        platform.getWaveformStream(configs(id: 'a')),
        into: first,
      );
      final secondDone = drain(
        platform.getWaveformStream(configs(id: 'b')),
        into: second,
      );
      await pumpEventQueue();

      sink!.success(chunk(0, [0.1], id: 'a', isComplete: true));
      await firstDone;
      await pumpEventQueue();
      sink!.success(chunk(0, [0.2], id: 'b', isComplete: true));
      await secondDone;

      expect(first, hasLength(1));
      expect(second, hasLength(1));
      expect(log.where((entry) => entry == 'listen'), hasLength(1));
    });
  });
}
