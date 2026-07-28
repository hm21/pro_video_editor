import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/video/chroma_key_model.dart';
import 'package:pro_video_editor/core/models/video/editor_video_model.dart';
import 'package:pro_video_editor/core/models/video/video_composition_model.dart';
import 'package:pro_video_editor/core/models/video/video_layer_model.dart';
import 'package:pro_video_editor/core/models/video/video_quality_config.dart';
import 'package:pro_video_editor/core/models/video/video_quality_preset.dart';
import 'package:pro_video_editor/core/models/video/video_render_data_model.dart';
import 'package:pro_video_editor/core/models/video/video_segment_model.dart';

void main() {
  group('VideoRenderData maxFrameRate', () {
    VideoRenderData buildData({int? maxFrameRate}) {
      return VideoRenderData(
        id: 'test',
        videoSegments: [VideoSegment(video: EditorVideo.file('test.mp4'))],
        maxFrameRate: maxFrameRate,
      );
    }

    test('defaults to null', () {
      expect(buildData().maxFrameRate, isNull);
    });

    test('asserts a positive value', () {
      expect(() => buildData(maxFrameRate: 0), throwsA(isA<AssertionError>()));
      expect(() => buildData(maxFrameRate: -5), throwsA(isA<AssertionError>()));
    });

    test('toMap serializes the value', () {
      expect(buildData(maxFrameRate: 30).toMap()['maxFrameRate'], 30);
      expect(buildData().toMap()['maxFrameRate'], isNull);
    });

    test('toMap / fromMap roundtrip preserves the value', () {
      final restored = VideoRenderData.fromMap(
        buildData(maxFrameRate: 24).toMap(),
      );
      expect(restored.maxFrameRate, 24);

      final restoredNull = VideoRenderData.fromMap(buildData().toMap());
      expect(restoredNull.maxFrameRate, isNull);
    });

    test('fromMap parses numeric strings safely', () {
      final map = buildData().toMap()..['maxFrameRate'] = '60';
      expect(VideoRenderData.fromMap(map).maxFrameRate, 60);
    });

    test('copyWith overrides and otherwise keeps the value', () {
      final overridden = buildData(maxFrameRate: 30).copyWith(maxFrameRate: 60);
      expect(overridden.maxFrameRate, 60);
      expect(buildData(maxFrameRate: 30).copyWith().maxFrameRate, 30);
    });

    test('withQualityPreset forwards the value', () {
      final data = VideoRenderData.withQualityPreset(
        videoSegments: [VideoSegment(video: EditorVideo.file('test.mp4'))],
        qualityPreset: VideoQualityPreset.p720,
        maxFrameRate: 30,
      );
      expect(data.maxFrameRate, 30);
    });
  });

  group('VideoRenderData qualityConfig output resolution', () {
    VideoRenderData buildData(VideoQualityConfig qualityConfig) {
      return VideoRenderData(
        id: 'test',
        videoSegments: [VideoSegment(video: EditorVideo.file('test.mp4'))],
        qualityConfig: qualityConfig,
      );
    }

    test(
      'custom resolution maps to an exact output canvas (no scale)',
      () async {
        final map = await buildData(
          VideoQualityConfig.custom(
            bitrate: 8000000,
            resolution: const Size(1080, 1920),
          ),
        ).toAsyncMap();

        // Exact output canvas → letterboxed natively, not a uniform scale.
        expect(map['outputWidth'], 1080);
        expect(map['outputHeight'], 1920);
        expect(map['scaleX'], isNull);
        expect(map['scaleY'], isNull);
      },
    );

    test('falls back to the quality config bitrate when none is set', () async {
      final map = await buildData(
        VideoQualityConfig.custom(
          bitrate: 8000000,
          resolution: const Size(1080, 1920),
        ),
      ).toAsyncMap();

      expect(map['bitrate'], 8000000);
    });
  });

  group('VideoRenderData trimToCommonTrackEnd', () {
    VideoRenderData buildData({bool? trimToCommonTrackEnd}) {
      return VideoRenderData(
        id: 'test',
        videoSegments: [VideoSegment(video: EditorVideo.file('test.mp4'))],
        trimToCommonTrackEnd: trimToCommonTrackEnd ?? false,
      );
    }

    test('defaults to off so exports keep their full length', () {
      expect(buildData().trimToCommonTrackEnd, isFalse);
    });

    test('toMap serializes the value', () {
      expect(
        buildData(trimToCommonTrackEnd: true).toMap()['trimToCommonTrackEnd'],
        isTrue,
      );
      expect(buildData().toMap()['trimToCommonTrackEnd'], isFalse);
    });

    test('toAsyncMap sends the value over the platform channel', () async {
      // toMap() is the Dart-side JSON form; toAsyncMap() is what actually
      // reaches RenderConfig.fromArgs, so the native key is asserted here.
      expect(
        (await buildData(
          trimToCommonTrackEnd: true,
        ).toAsyncMap())['trimToCommonTrackEnd'],
        isTrue,
      );
      expect((await buildData().toAsyncMap())['trimToCommonTrackEnd'], isFalse);
    });

    test('toMap / fromMap roundtrip preserves the value', () {
      final restored = VideoRenderData.fromMap(
        buildData(trimToCommonTrackEnd: true).toMap(),
      );
      expect(restored.trimToCommonTrackEnd, isTrue);
    });

    test('fromMap defaults to off for payloads without the key', () {
      final map = buildData(trimToCommonTrackEnd: true).toMap()
        ..remove('trimToCommonTrackEnd');

      expect(VideoRenderData.fromMap(map).trimToCommonTrackEnd, isFalse);
    });

    test('copyWith overrides the value', () {
      expect(
        buildData().copyWith(trimToCommonTrackEnd: true).trimToCommonTrackEnd,
        isTrue,
      );
      expect(
        buildData(trimToCommonTrackEnd: true).copyWith().trimToCommonTrackEnd,
        isTrue,
      );
    });
  });

  group('VideoRenderData chromaKey', () {
    const key = ChromaKey(backgroundColor: Color(0xFFFF0000));

    VideoRenderData buildData({ChromaKey? chromaKey}) {
      return VideoRenderData(
        id: 'test',
        videoSegments: [VideoSegment(video: EditorVideo.file('test.mp4'))],
        chromaKey: chromaKey,
      );
    }

    test('defaults to null', () {
      expect(buildData().chromaKey, isNull);
    });

    test('rejects a transparent key on the single-track path', () {
      // videoSegments has nothing underneath and the codec carries no alpha,
      // so a background-less key would silently flatten to black.
      expect(
        () => buildData(chromaKey: const ChromaKey()),
        throwsA(isA<AssertionError>()),
      );
    });

    test('allows a transparent key inside a composition', () {
      expect(
        VideoRenderData(
          id: 'test',
          composition: VideoComposition(
            layers: [
              VideoLayer(
                clips: [VideoSegment(video: EditorVideo.file('test.mp4'))],
              ),
            ],
          ),
          chromaKey: const ChromaKey(),
        ).chromaKey,
        const ChromaKey(),
      );
    });

    test('toAsyncMap sends the key over the platform channel', () async {
      // toMap() is the Dart-side JSON form; toAsyncMap() is what actually
      // reaches the native RenderConfig, so the wire keys are asserted here.
      final map = (await buildData(chromaKey: key).toAsyncMap())['chromaKey'];

      expect(map, isA<Map<String, dynamic>>());
      expect((map as Map)['keyColor'], 0xFF00B140);
      expect(map['bgColor'], 0xFFFF0000);
    });

    test('toAsyncMap omits the key when unset', () async {
      expect((await buildData().toAsyncMap())['chromaKey'], isNull);
    });

    test('toMap / fromMap roundtrip preserves the key', () {
      final restored = VideoRenderData.fromMap(
        buildData(chromaKey: key).toMap(),
      );

      expect(restored.chromaKey, key);
      expect(VideoRenderData.fromMap(buildData().toMap()).chromaKey, isNull);
    });

    test('copyWith overrides and otherwise keeps the key', () {
      const other = ChromaKey(backgroundColor: Color(0xFF0000FF));

      expect(buildData(chromaKey: key).copyWith(chromaKey: other).chromaKey,
          other);
      expect(buildData(chromaKey: key).copyWith().chromaKey, key);
    });

    test('withQualityPreset forwards the key', () {
      final data = VideoRenderData.withQualityPreset(
        videoSegments: [VideoSegment(video: EditorVideo.file('test.mp4'))],
        qualityPreset: VideoQualityPreset.p720,
        chromaKey: key,
      );

      expect(data.chromaKey, key);
    });
  });
}
