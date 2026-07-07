import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/video/editor_video_model.dart';
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
}
