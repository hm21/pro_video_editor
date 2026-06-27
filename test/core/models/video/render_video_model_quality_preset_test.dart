import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('VideoRenderData.withQualityPreset', () {
    final testVideo = EditorVideo.asset('test_video.mp4');

    test('creates model with 1080p quality preset', () {
      final model = VideoRenderData.withQualityPreset(
        videoSegments: [VideoSegment(video: testVideo)],
        qualityPreset: VideoQualityPreset.p1080,
      );

      expect(model.videoSegments!.first.video, equals(testVideo));
      expect(model.bitrate, equals(8000000)); // 8 Mbps
      expect(model.outputFormat, equals(VideoOutputFormat.mp4));
      expect(model.enableAudio, isTrue);
    });

    test('creates model with 720p quality preset', () {
      final model = VideoRenderData.withQualityPreset(
        videoSegments: [VideoSegment(video: testVideo)],
        qualityPreset: VideoQualityPreset.p720,
      );

      expect(model.bitrate, equals(3000000)); // 3 Mbps
      final resolution = model.qualityConfig?.resolution;
      expect(resolution?.width, equals(1280));
      expect(resolution?.height, equals(720));
    });

    test('creates model with 4K quality preset', () {
      final model = VideoRenderData.withQualityPreset(
        videoSegments: [VideoSegment(video: testVideo)],
        qualityPreset: VideoQualityPreset.k4,
      );

      expect(model.bitrate, equals(35000000)); // 35 Mbps
      final resolution = model.qualityConfig?.resolution;
      expect(resolution?.width, equals(3840));
      expect(resolution?.height, equals(2160));
    });

    test('allows bitrate override', () {
      final model = VideoRenderData.withQualityPreset(
        videoSegments: [VideoSegment(video: testVideo)],
        qualityPreset: VideoQualityPreset.p1080,
        bitrateOverride: 12000000,
      );

      expect(model.bitrate, equals(12000000));
    });

    test('respects custom transform parameter', () {
      const customTransform = ExportTransform(flipX: true, rotateTurns: 1);

      final model = VideoRenderData.withQualityPreset(
        videoSegments: [VideoSegment(video: testVideo)],
        qualityPreset: VideoQualityPreset.p1080,
        transform: customTransform,
      );

      expect(model.transform, equals(customTransform));
      expect(model.transform?.flipX, isTrue);
      expect(model.transform?.rotateTurns, equals(1));
    });

    test('creates model with all optional parameters', () {
      final model = VideoRenderData.withQualityPreset(
        videoSegments: [VideoSegment(video: testVideo)],
        qualityPreset: VideoQualityPreset.p720,
        outputFormat: VideoOutputFormat.mov,
        enableAudio: false,
        startTime: const Duration(seconds: 5),
        endTime: const Duration(seconds: 10),
        blur: 5.0,
        colorFilters: const [
          ColorFilter(
            matrix: [
              1.0, 0.0, 0.0, 0.0, 0.0, //
              0.0, 1.0, 0.0, 0.0, 0.0, //
              0.0, 0.0, 1.0, 0.0, 0.0, //
              0.0, 0.0, 0.0, 1.0, 0.0, //
            ],
          ),
        ],
      );

      expect(model.outputFormat, equals(VideoOutputFormat.mov));
      expect(model.enableAudio, isFalse);
      expect(model.startTime, equals(const Duration(seconds: 5)));
      expect(model.endTime, equals(const Duration(seconds: 10)));
      expect(model.blur, equals(5.0));
      expect(model.colorFilters.length, equals(1));
    });

    test('creates model with custom ID', () {
      final model = VideoRenderData.withQualityPreset(
        videoSegments: [VideoSegment(video: testVideo)],
        qualityPreset: VideoQualityPreset.p1080,
        id: 'custom-task-id',
      );

      expect(model.id, equals('custom-task-id'));
    });

    test('creates model with low quality preset', () {
      final model = VideoRenderData.withQualityPreset(
        videoSegments: [VideoSegment(video: testVideo)],
        qualityPreset: VideoQualityPreset.low,
      );

      expect(model.bitrate, equals(1000000)); // 1 Mbps
      final resolution = model.qualityConfig?.resolution;
      expect(resolution?.width, equals(640));
      expect(resolution?.height, equals(360));
    });

    test('creates model with ultra 4K preset', () {
      final model = VideoRenderData.withQualityPreset(
        videoSegments: [VideoSegment(video: testVideo)],
        qualityPreset: VideoQualityPreset.ultra4K,
      );

      expect(model.bitrate, equals(45000000)); // 45 Mbps
      final resolution = model.qualityConfig?.resolution;
      expect(resolution?.width, equals(3840));
      expect(resolution?.height, equals(2160));
    });

    test('custom preset does not set transform', () {
      final model = VideoRenderData.withQualityPreset(
        videoSegments: [VideoSegment(video: testVideo)],
        qualityPreset: VideoQualityPreset.custom,
      );

      expect(model.bitrate, equals(8000000)); // Default 8 Mbps
      expect(model.transform, isNull);
    });
  });
}
