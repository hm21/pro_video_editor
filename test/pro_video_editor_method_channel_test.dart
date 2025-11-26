import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor/pro_video_editor_method_channel.dart';

import 'pro_video_editor_method_channel_test.mocks.dart';

@GenerateMocks([
  EditorVideo,
  ThumbnailConfigs,
  KeyFramesConfigs,
  RenderVideoModel,
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
          return {
            'duration': 1200,
            'width': 1920,
            'height': 1080,
            'rotation': 90,
            'extension': 'mp4',
          };
        case 'getThumbnails':
          return [mockBytes, mockBytes];
        case 'renderVideo':
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

    expect(result.originalResolution.width, 1920);
    expect(result.originalResolution.height, 1080);

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
    final mockModel = MockRenderVideoModel();

    when(mockModel.video).thenReturn(mockVideo);
    when(mockModel.toAsyncMap()).thenAnswer((_) async => {
          'inputPath': 'test.mp4',
        });

    final result = await platform.renderVideo(mockModel);
    expect(result, isA<Uint8List>());
    expect(result.length, 10);
  });

  test('renderVideo throws if result is null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return null;
    });

    final mockModel = MockRenderVideoModel();
    final mockVideo = MockEditorVideo();

    when(mockModel.video).thenReturn(mockVideo);
    when(mockModel.toAsyncMap()).thenAnswer((_) async => {
          'inputPath': 'test.mp4',
        });

    expect(
        () async => await platform.renderVideo(mockModel), throwsArgumentError);
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
}
