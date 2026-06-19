import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('StopMotionFrame', () {
    final image = EditorLayerImage.memory(Uint8List.fromList([1, 2, 3, 4]));

    test('toAsyncMap serializes image bytes and duration', () async {
      final frame = StopMotionFrame(
        image: image,
        duration: const Duration(milliseconds: 200),
      );
      final map = await frame.toAsyncMap();

      expect(map['imageData'], isA<Uint8List>());
      expect((map['imageData'] as Uint8List).toList(), [1, 2, 3, 4]);
      expect(map['durationUs'], 200000);
    });

    test('toAsyncMap leaves durationUs null when not set', () async {
      final frame = StopMotionFrame(image: image);
      final map = await frame.toAsyncMap();

      expect(map['durationUs'], isNull);
    });

    test('toMap / fromMap roundtrip preserves data', () {
      final frame = StopMotionFrame(
        image: EditorLayerImage.asset('assets/frame.png'),
        duration: const Duration(seconds: 1),
      );
      final restored = StopMotionFrame.fromMap(frame.toMap());

      expect(restored.image.assetPath, 'assets/frame.png');
      expect(restored.duration, const Duration(seconds: 1));
    });
  });

  group('StopMotionRenderData', () {
    final frames = [
      StopMotionFrame(image: EditorLayerImage.memory(Uint8List.fromList([1]))),
      StopMotionFrame(
        image: EditorLayerImage.memory(Uint8List.fromList([2])),
        duration: const Duration(milliseconds: 500),
      ),
    ];

    test('applies sensible defaults', () {
      final data = StopMotionRenderData(frames: frames);

      expect(data.frameRate, 12);
      expect(data.fit, StopMotionFit.contain);
      expect(data.outputFormat, VideoOutputFormat.mp4);
      expect(data.resolution, isNull);
      expect(data.id, isNotEmpty);
    });

    test('throws when frames are empty', () {
      expect(
        () => StopMotionRenderData(frames: const []),
        throwsAssertionError,
      );
    });

    test('throws when frameRate is not positive', () {
      expect(
        () => StopMotionRenderData(frames: frames, frameRate: 0),
        throwsAssertionError,
      );
    });

    group('toAsyncMap', () {
      test('serializes frames, frameRate, fit and format', () async {
        final data = StopMotionRenderData(
          id: 'task-1',
          frames: frames,
          frameRate: 8,
          fit: StopMotionFit.cover,
        );
        final map = await data.toAsyncMap();

        expect(map['id'], 'task-1');
        expect(map['frameRate'], 8);
        expect(map['fit'], 'cover');
        expect(map['outputFormat'], 'mp4');

        final frameMaps = map['frames'] as List;
        expect(frameMaps, hasLength(2));
        expect((frameMaps.first as Map)['imageData'], isA<Uint8List>());
        expect((frameMaps.last as Map)['durationUs'], 500000);
      });

      test('uses explicit resolution for width/height', () async {
        final data = StopMotionRenderData(
          frames: frames,
          resolution: const Size(640, 480),
        );
        final map = await data.toAsyncMap();

        expect(map['width'], 640);
        expect(map['height'], 480);
      });

      test('leaves width/height null without resolution', () async {
        final data = StopMotionRenderData(frames: frames);
        final map = await data.toAsyncMap();

        expect(map['width'], isNull);
        expect(map['height'], isNull);
      });

      test('falls back to qualityConfig bitrate and resolution', () async {
        final data = StopMotionRenderData.withQualityPreset(
          frames: frames,
          qualityPreset: VideoQualityPreset.p720,
        );
        final map = await data.toAsyncMap();

        expect(map['bitrate'], isNotNull);
        expect(map['width'], isNotNull);
        expect(map['height'], isNotNull);
      });
    });

    group('toMap / fromMap', () {
      test('roundtrip preserves scalar fields', () {
        final data = StopMotionRenderData(
          id: 'task-2',
          frames: frames,
          frameRate: 15,
          fit: StopMotionFit.stretch,
          resolution: const Size(320, 240),
          bitrate: 2000000,
        );
        final restored = StopMotionRenderData.fromMap(data.toMap());

        expect(restored.id, 'task-2');
        expect(restored.frameRate, 15);
        expect(restored.fit, StopMotionFit.stretch);
        expect(restored.resolution, const Size(320, 240));
        expect(restored.bitrate, 2000000);
        expect(restored.frames, hasLength(2));
      });
    });

    group('copyWith', () {
      test('updates only provided fields', () {
        final data = StopMotionRenderData(frames: frames);
        final copy = data.copyWith(frameRate: 24, fit: StopMotionFit.cover);

        expect(copy.frameRate, 24);
        expect(copy.fit, StopMotionFit.cover);
        expect(copy.id, data.id);
        expect(copy.frames, data.frames);
      });
    });

    test('toString contains class name', () {
      final data = StopMotionRenderData(frames: frames);
      expect(data.toString(), contains('StopMotionRenderData'));
    });
  });
}
