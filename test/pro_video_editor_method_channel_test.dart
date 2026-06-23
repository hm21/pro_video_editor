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

    when(mockModel.video).thenReturn(mockVideo);
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
    final mockVideo = MockEditorVideo();

    when(mockModel.video).thenReturn(mockVideo);
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
}
