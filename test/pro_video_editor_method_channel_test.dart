import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:pro_video_editor/core/platform/native_method_channel.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

import 'pro_video_editor_method_channel_test.mocks.dart';

@GenerateMocks([
  EditorVideo,
  ThumbnailConfigs,
  KeyFramesConfigs,
  VideoRenderData,
])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelProVideoEditor platform = MethodChannelProVideoEditor();
  const MethodChannel channel = MethodChannel('pro_video_editor');
  final mockVideo = MockEditorVideo();
  final mockBytes = Uint8List.fromList([0x00, 0x01]);
  const mockFilePath = '';

  setUp(() {
    when(mockVideo.safeFilePath()).thenAnswer((_) async => mockFilePath);
    when(mockVideo.safeByteArray()).thenAnswer((_) async => mockBytes);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'getPlatformVersion':
              return '42';
            case 'getMetadata':
              // Native platforms now return display dimensions (after rotation)
              // For a 90° rotated video, width and height are already swapped
              return {
                'duration': 1200,
                'width': 1080, // Display width (after 90° rotation)
                'height': 1920, // Display height (after 90° rotation)
                'rotation': 90,
                'extension': 'mp4',
              };
            case 'getThumbnails':
              return [mockBytes, mockBytes];
            case 'renderVideo':
              return Uint8List(10);
            case 'renderStopMotion':
              return Uint8List(10);
            case 'cancelTask':
              return null;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('getMetadata returns correct metadata', () async {
    final result = await platform.getMetadata(mockVideo);

    expect(result.duration.inMilliseconds, 1200);

    expect(result.resolution.width, 1080);
    expect(result.resolution.height, 1920);

    expect(result.rawResolution.width, 1920);
    expect(result.rawResolution.height, 1080);

    expect(result.rotation, 90);
    expect(result.extension, 'mp4');
  });

  test('getThumbnails returns list of Uint8List', () async {
    final mockConfig = MockThumbnailConfigs();

    when(mockConfig.video).thenReturn(mockVideo);
    when(mockConfig.toMap()).thenReturn({});

    final thumbnails = await platform.getThumbnails(mockConfig);
    expect(thumbnails.length, 2);
    expect(thumbnails[0], isA<Uint8List>());
  });

  test('getKeyFrames returns list of Uint8List', () async {
    final mockConfig = MockKeyFramesConfigs();

    when(mockConfig.video).thenReturn(mockVideo);
    when(mockConfig.toMap()).thenReturn({});

    final keyframes = await platform.getKeyFrames(mockConfig);
    expect(keyframes.length, 2);
    expect(keyframes[1], isA<Uint8List>());
  });

  test('renderVideo returns rendered video bytes', () async {
    final mockModel = MockVideoRenderData();

    when(mockModel.id).thenReturn('test-render-id');
    when(
      mockModel.toAsyncMap(),
    ).thenAnswer((_) async => {'inputPath': 'test.mp4'});

    final result = await platform.renderVideo(mockModel);
    expect(result, isA<Uint8List>());
    expect(result.length, 10);
  });

  test('renderVideo throws if result is null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return null;
        });

    final mockModel = MockVideoRenderData();

    when(mockModel.id).thenReturn('test-render-id');
    when(
      mockModel.toAsyncMap(),
    ).thenAnswer((_) async => {'inputPath': 'test.mp4'});

    expect(
      () async => await platform.renderVideo(mockModel),
      throwsArgumentError,
    );
  });

  test('renderStopMotion returns rendered video bytes', () async {
    final data = StopMotionRenderData(
      frames: [StopMotionFrame(image: EditorLayerImage.memory(mockBytes))],
      frameRate: 8,
    );

    final result = await platform.renderStopMotion(data);
    expect(result, isA<Uint8List>());
    expect(result.length, 10);
  });

  test(
    'renderStopMotionToFile invokes renderStopMotion with outputPath',
    () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            capturedCall = methodCall;
            return null;
          });

      final data = StopMotionRenderData(
        frames: [StopMotionFrame(image: EditorLayerImage.memory(mockBytes))],
      );

      final path = await platform.renderStopMotionToFile('/tmp/out.mp4', data);

      expect(path, '/tmp/out.mp4');
      expect(capturedCall?.method, 'renderStopMotion');
      final args = capturedCall?.arguments as Map;
      expect(args['outputPath'], '/tmp/out.mp4');
      expect(args['frames'], isA<List<dynamic>>());
      expect(args['frames'] as List<dynamic>, hasLength(1));
    },
  );

  group('encoder failures', () {
    MockVideoRenderData renderData() {
      final mockModel = MockVideoRenderData();
      when(mockModel.id).thenReturn('test-render-id');
      when(
        mockModel.toAsyncMap(),
      ).thenAnswer((_) async => {'inputPath': 'test.mp4'});
      return mockModel;
    }

    void throwPlatformError(String code) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
            throw PlatformException(code: code, message: 'boom');
          });
    }

    test('ENCODER_NOT_SUPPORTED maps to a permanent failure', () async {
      throwPlatformError('ENCODER_NOT_SUPPORTED');

      await expectLater(
        platform.renderVideo(renderData()),
        throwsA(
          isA<RenderEncoderException>()
              .having((e) => e.isTransient, 'isTransient', isFalse)
              .having((e) => e.message, 'message', 'boom'),
        ),
      );
    });

    test('CODEC_RESOURCE_EXHAUSTED maps to a transient failure', () async {
      throwPlatformError('CODEC_RESOURCE_EXHAUSTED');

      await expectLater(
        platform.renderVideo(renderData()),
        throwsA(
          isA<RenderEncoderException>()
              .having((e) => e.isTransient, 'isTransient', isTrue)
              .having((e) => e.message, 'message', 'boom'),
        ),
      );
    });

    test('renderVideoToFile maps the transient code too', () async {
      throwPlatformError('CODEC_RESOURCE_EXHAUSTED');

      await expectLater(
        platform.renderVideoToFile('/tmp/out.mp4', renderData()),
        throwsA(
          isA<RenderEncoderException>().having(
            (e) => e.isTransient,
            'isTransient',
            isTrue,
          ),
        ),
      );
    });

    test('splitVideo maps both encoder codes', () async {
      SplitVideoModel splitData() => SplitVideoModel(
        id: 'split-encoder-id',
        video: mockVideo,
        splitPosition: const Duration(seconds: 1),
        startOutputPath: '/tmp/start.mp4',
        endOutputPath: '/tmp/end.mp4',
      );

      throwPlatformError('CODEC_RESOURCE_EXHAUSTED');
      await expectLater(
        platform.splitVideo(splitData()),
        throwsA(
          isA<RenderEncoderException>().having(
            (e) => e.isTransient,
            'isTransient',
            isTrue,
          ),
        ),
      );

      throwPlatformError('ENCODER_NOT_SUPPORTED');
      await expectLater(
        platform.splitVideo(splitData()),
        throwsA(
          isA<RenderEncoderException>().having(
            (e) => e.isTransient,
            'isTransient',
            isFalse,
          ),
        ),
      );
    });

    test('an unrelated platform error is rethrown untouched', () async {
      throwPlatformError('RENDER_ERROR');

      await expectLater(
        platform.renderVideo(renderData()),
        throwsA(isA<PlatformException>()),
      );
    });

    test('toString marks the transient case only', () {
      expect(
        const RenderEncoderException('boom').toString(),
        'RenderEncoderException: boom',
      );
      expect(
        const RenderEncoderException.transient('boom').toString(),
        'RenderEncoderException(transient): boom',
      );
      expect(
        const RenderEncoderException().toString(),
        'RenderEncoderException',
      );
    });
  });

  test('cancel forwards to platform channel', () async {
    MethodCall? capturedCall;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          capturedCall = methodCall;
          return null;
        });

    const taskId = 'task-123';
    await platform.cancel(taskId);

    expect(capturedCall?.method, 'cancelTask');
    final args = capturedCall?.arguments as Map<dynamic, dynamic>?;
    expect(args?['id'], taskId);
  });

  test('cancel throws when taskId is empty', () {
    expect(() => platform.cancel(''), throwsArgumentError);
  });

  group('splitVideo', () {
    SplitVideoModel model({Duration? exportTimeout, Duration? stallTimeout}) {
      return SplitVideoModel(
        id: 'split-id',
        video: mockVideo,
        splitPosition: const Duration(seconds: 1),
        startOutputPath: '/tmp/start.mp4',
        endOutputPath: '/tmp/end.mp4',
        exportTimeout: exportTimeout ?? const Duration(seconds: 120),
        stallTimeout: stallTimeout ?? const Duration(seconds: 12),
      );
    }

    test('sends default export/stall timeouts to native', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            capturedCall = methodCall;
            return null;
          });

      final paths = await platform.splitVideo(
        SplitVideoModel(
          id: 'split-id',
          video: mockVideo,
          splitPosition: const Duration(seconds: 1),
          startOutputPath: '/tmp/start.mp4',
          endOutputPath: '/tmp/end.mp4',
        ),
      );

      expect(paths, ['/tmp/start.mp4', '/tmp/end.mp4']);
      expect(capturedCall?.method, 'splitVideo');
      final args = capturedCall?.arguments as Map;
      expect(args['exportTimeoutMs'], 120000);
      expect(args['stallTimeoutMs'], 12000);
    });

    test('forwards custom export/stall timeouts to native', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            capturedCall = methodCall;
            return null;
          });

      await platform.splitVideo(
        model(
          exportTimeout: const Duration(seconds: 30),
          stallTimeout: const Duration(milliseconds: 4500),
        ),
      );

      final args = capturedCall?.arguments as Map;
      expect(args['exportTimeoutMs'], 30000);
      expect(args['stallTimeoutMs'], 4500);
    });

    test('SplitVideoModel rejects non-positive timeouts', () {
      expect(
        () => SplitVideoModel(
          video: mockVideo,
          splitPosition: const Duration(seconds: 1),
          startOutputPath: '/tmp/start.mp4',
          endOutputPath: '/tmp/end.mp4',
          stallTimeout: Duration.zero,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('SplitVideoModel rejects stallTimeout >= exportTimeout', () {
      expect(
        () => SplitVideoModel(
          video: mockVideo,
          splitPosition: const Duration(seconds: 1),
          startOutputPath: '/tmp/start.mp4',
          endOutputPath: '/tmp/end.mp4',
          exportTimeout: const Duration(seconds: 10),
          stallTimeout: const Duration(seconds: 10),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('getSingleThumbnail', () {
    test('first position returns thumbnail', () async {
      final result = await platform.getSingleThumbnail(
        SingleThumbnailConfigs(
          video: mockVideo,
          outputSize: const Size(100, 100),
          position: ThumbnailPosition.first,
        ),
      );

      expect(result, isA<Uint8List>());
      expect(result, mockBytes);
    });

    test('last position with provided duration returns thumbnail', () async {
      final result = await platform.getSingleThumbnail(
        SingleThumbnailConfigs(
          video: mockVideo,
          outputSize: const Size(100, 100),
          position: ThumbnailPosition.last,
          videoDuration: const Duration(seconds: 10),
        ),
      );

      expect(result, isA<Uint8List>());
      expect(result, mockBytes);
    });

    test('last position without duration fetches metadata', () async {
      final result = await platform.getSingleThumbnail(
        SingleThumbnailConfigs(
          video: mockVideo,
          outputSize: const Size(100, 100),
          position: ThumbnailPosition.last,
        ),
      );

      expect(result, isA<Uint8List>());
      expect(result, mockBytes);
    });

    test('returns null when native returns empty list', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            switch (methodCall.method) {
              case 'getThumbnails':
                return <Uint8List>[];
              case 'getMetadata':
                return {
                  'duration': 1200,
                  'width': 1080,
                  'height': 1920,
                  'rotation': 0,
                  'extension': 'mp4',
                };
              default:
                return null;
            }
          });

      final result = await platform.getSingleThumbnail(
        SingleThumbnailConfigs(
          video: mockVideo,
          outputSize: const Size(100, 100),
          position: ThumbnailPosition.first,
        ),
      );

      expect(result, isNull);
    });

    test('sends lastFrameTolerance true for last position', () async {
      Map<dynamic, dynamic>? capturedArgs;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            if (methodCall.method == 'getThumbnails') {
              capturedArgs = methodCall.arguments as Map<dynamic, dynamic>;
              return [mockBytes];
            }
            return null;
          });

      await platform.getSingleThumbnail(
        SingleThumbnailConfigs(
          video: mockVideo,
          outputSize: const Size(100, 100),
          position: ThumbnailPosition.last,
          videoDuration: const Duration(seconds: 5),
        ),
      );

      expect(capturedArgs?['lastFrameTolerance'], isTrue);
      expect(capturedArgs?['timestamps'], [5000000]);
    });

    test('sends lastFrameTolerance false for first position', () async {
      Map<dynamic, dynamic>? capturedArgs;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            if (methodCall.method == 'getThumbnails') {
              capturedArgs = methodCall.arguments as Map<dynamic, dynamic>;
              return [mockBytes];
            }
            return null;
          });

      await platform.getSingleThumbnail(
        SingleThumbnailConfigs(
          video: mockVideo,
          outputSize: const Size(100, 100),
          position: ThumbnailPosition.first,
        ),
      );

      expect(capturedArgs?['lastFrameTolerance'], isFalse);
      expect(capturedArgs?['timestamps'], [0]);
    });
  });

  group('mergeAudioToFile', () {
    List<AudioMergeSegment> twoSegments() => [
      AudioMergeSegment(
        video: mockVideo,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
      ),
      AudioMergeSegment(
        video: mockVideo,
        startTime: const Duration(seconds: 1),
        endTime: const Duration(seconds: 3),
        speed: 2.0,
      ),
    ];

    test('invokes mergeAudio with ordered segments, parses result', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
            capturedCall = methodCall;
            return {
              'outputPath': '/tmp/out.wav',
              'totalDurationUs': 3000000,
              'segments': [
                {'outputStartUs': 0, 'outputDurationUs': 2000000},
                {'outputStartUs': 2000000, 'outputDurationUs': 1000000},
              ],
            };
          });

      final result = await platform.mergeAudioToFile(
        '/tmp/out.wav',
        AudioMergeConfigs(
          segments: twoSegments(),
          sampleRate: 16000,
          channels: 1,
        ),
      );

      expect(capturedCall?.method, 'mergeAudio');
      final args = capturedCall?.arguments as Map;
      expect(args['outputPath'], '/tmp/out.wav');
      expect(args['format'], 'wav');
      expect(args['sampleRate'], 16000);
      expect(args['channels'], 1);

      final segments = args['segments'] as List;
      expect(segments, hasLength(2));
      final first = segments[0] as Map;
      expect(first['startTime'], 0);
      expect(first['endTime'], 2000000);
      expect(first['speed'], 1.0);
      final second = segments[1] as Map;
      expect(second['startTime'], 1000000);
      expect(second['endTime'], 3000000);
      expect(second['speed'], 2.0);

      expect(result.outputPath, '/tmp/out.wav');
      expect(result.totalDuration, const Duration(seconds: 3));
      expect(result.segments, hasLength(2));
      expect(result.segments[0].outputStart, Duration.zero);
      expect(result.segments[0].outputDuration, const Duration(seconds: 2));
      expect(result.segments[1].outputStart, const Duration(seconds: 2));
      expect(result.segments[1].outputDuration, const Duration(seconds: 1));
    });

    test('empty segments throws ArgumentError, skips native', () async {
      var invoked = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
            invoked = true;
            return null;
          });

      await expectLater(
        platform.mergeAudioToFile(
          '/tmp/out.wav',
          AudioMergeConfigs(segments: const []),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(invoked, isFalse);
    });

    test('AudioMergeSegment rejects endTime <= startTime', () {
      expect(
        () => AudioMergeSegment(
          video: mockVideo,
          startTime: const Duration(seconds: 3),
          endTime: const Duration(seconds: 1),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('AudioMergeSegment rejects non-positive speed', () {
      expect(
        () => AudioMergeSegment(
          video: mockVideo,
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
          speed: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('maps CANCELED to RenderCanceledException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
            throw PlatformException(code: 'CANCELED');
          });

      await expectLater(
        platform.mergeAudioToFile(
          '/tmp/out.wav',
          AudioMergeConfigs(segments: twoSegments()),
        ),
        throwsA(isA<RenderCanceledException>()),
      );
    });
  });
}
