import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
  final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;

  // Test video assets as described in integration_test.md
  const testAPath =
      'assets/tests/test_a.mp4'; // Baseline 1920×1080, 30fps, H.264, AAC stereo
  const testBPath =
      'assets/tests/test_b.mp4'; // Portrait 720×1280, 30fps, rotation metadata
  const testCPath = 'assets/tests/test_c.mp4'; // 1920×1080, 60fps
  const testDPath = 'assets/tests/test_d.mp4'; // 1920×1080, 30fps, no audio
  const testEPath = 'assets/tests/test_e.mp4'; // 1920×1080, 30fps, HEVC
  const testFPath = 'assets/tests/test_f.mp4'; // AC3 Dolby Digital, 448kbps
  const test4kAPath = 'assets/tests/test_4k_a.mp4'; // 4K video, ~61.43MB
  const test4kBPath = 'assets/tests/test_4k_b.mp4'; // 4K video, ~49.3MB

  // Tolerance for duration comparison (in seconds)
  const durationTolerance = 0.2;

  const enable4kTests = false;
  const enableMergeAudioTests = false;

  group('Video Merging - Basic Tests', () {
    testWidgets('Merge two identical baseline videos (A + A)', (tester) async {
      final videoA1 = EditorVideo.asset(testAPath);
      final videoA2 = EditorVideo.asset(testAPath);

      final metadataA = await ProVideoEditor.instance.getMetadata(videoA1);
      final expectedDuration = metadataA.duration * 2;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA1),
            VideoSegment(video: videoA2),
          ],
        ),
      );

      expect(result, isNotNull);
      expect(
        result.lengthInBytes,
        greaterThan(100000),
        reason: 'Merged video should have reasonable file size',
      );

      // Verify output metadata
      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Total duration should match sum of inputs',
      );
      expect(
        outputMeta.resolution,
        equals(metadataA.resolution),
        reason: 'Resolution should match input',
      );
      expect(outputMeta.extension, equals('mp4'));
    });

    testWidgets('Merge three baseline videos (A + A + A)', (tester) async {
      final videoA1 = EditorVideo.asset(testAPath);
      final videoA2 = EditorVideo.asset(testAPath);
      final videoA3 = EditorVideo.asset(testAPath);

      final metadataA = await ProVideoEditor.instance.getMetadata(videoA1);
      final expectedDuration = metadataA.duration * 3;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA1),
            VideoSegment(video: videoA2),
            VideoSegment(video: videoA3),
          ],
        ),
      );

      expect(result, isNotNull);
      expect(result.lengthInBytes, greaterThan(150000));

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Duration should equal sum of three clips',
      );
    });

    testWidgets('Merge with trimmed segments', (tester) async {
      final videoA = EditorVideo.asset(testAPath);
      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);

      // Trim 2 seconds from start and end of each clip
      const trimStart = Duration(seconds: 2);
      final trimEnd = Duration(seconds: metadataA.duration.inSeconds - 2);

      final expectedClipDuration = trimEnd - trimStart;
      final expectedTotalDuration = expectedClipDuration * 2;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA, startTime: trimStart, endTime: trimEnd),
            VideoSegment(
              video: EditorVideo.asset(testAPath),
              startTime: trimStart,
              endTime: trimEnd,
            ),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedTotalDuration.inSeconds, durationTolerance),
        reason: 'Duration should match sum of trimmed segments',
      );
    });
  });

  group('Video Merging - Resolution & Aspect Ratio', () {
    testWidgets('Merge landscape (A) with portrait (B)', (tester) async {
      final videoA = EditorVideo.asset(testAPath);
      final videoB = EditorVideo.asset(testBPath);

      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);
      final metadataB = await ProVideoEditor.instance.getMetadata(videoB);

      final expectedDuration = metadataA.duration + metadataB.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA),
            VideoSegment(video: videoB),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Duration should match sum of inputs',
      );

      // The output should handle aspect ratio changes gracefully
      // (letterboxing/pillarboxing may be applied)
      expect(outputMeta.resolution.width, greaterThan(0));
      expect(outputMeta.resolution.height, greaterThan(0));
    });

    testWidgets('Merge portrait (B) with landscape (A)', (tester) async {
      final videoB = EditorVideo.asset(testBPath);
      final videoA = EditorVideo.asset(testAPath);

      final metadataB = await ProVideoEditor.instance.getMetadata(videoB);
      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);

      final expectedDuration = metadataB.duration + metadataA.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoB),
            VideoSegment(video: videoA),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Duration should match regardless of clip order',
      );
    });

    testWidgets('Merge multiple different aspect ratios (A + B + A)', (
      tester,
    ) async {
      final videoA1 = EditorVideo.asset(testAPath);
      final videoB = EditorVideo.asset(testBPath);
      final videoA2 = EditorVideo.asset(testAPath);

      final metadataA = await ProVideoEditor.instance.getMetadata(videoA1);
      final metadataB = await ProVideoEditor.instance.getMetadata(videoB);

      final expectedDuration =
          metadataA.duration + metadataB.duration + metadataA.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA1),
            VideoSegment(video: videoB),
            VideoSegment(video: videoA2),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
      );
    });
  });

  group('Video Merging - Frame Rate', () {
    testWidgets('Merge 30fps (A) with 60fps (C)', (tester) async {
      final videoA = EditorVideo.asset(testAPath);
      final videoC = EditorVideo.asset(testCPath);

      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);
      final metadataC = await ProVideoEditor.instance.getMetadata(videoC);

      final expectedDuration = metadataA.duration + metadataC.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA),
            VideoSegment(video: videoC),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Frame rate conversion should preserve duration',
      );
    });

    testWidgets('Merge 60fps (C) with 30fps (A)', (tester) async {
      final videoC = EditorVideo.asset(testCPath);
      final videoA = EditorVideo.asset(testAPath);

      final metadataC = await ProVideoEditor.instance.getMetadata(videoC);
      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);

      final expectedDuration = metadataC.duration + metadataA.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoC),
            VideoSegment(video: videoA),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Reverse order should also work correctly',
      );
    });

    testWidgets('Merge multiple frame rates (A + C + A)', (tester) async {
      final videoA1 = EditorVideo.asset(testAPath);
      final videoC = EditorVideo.asset(testCPath);
      final videoA2 = EditorVideo.asset(testAPath);

      final metadataA = await ProVideoEditor.instance.getMetadata(videoA1);
      final metadataC = await ProVideoEditor.instance.getMetadata(videoC);

      final expectedDuration =
          metadataA.duration + metadataC.duration + metadataA.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA1),
            VideoSegment(video: videoC),
            VideoSegment(video: videoA2),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
      );
    });
  });

  group('Video Merging - Audio Handling', () {
    testWidgets('Merge video with audio (A) and video without audio (D)', (
      tester,
    ) async {
      final videoA = EditorVideo.asset(testAPath);
      final videoD = EditorVideo.asset(testDPath);

      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);
      final metadataD = await ProVideoEditor.instance.getMetadata(videoD);

      final expectedDuration = metadataA.duration + metadataD.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA),
            VideoSegment(video: videoD),
          ],
        ),
      );

      expect(result, isNotNull);
      expect(result.lengthInBytes, greaterThan(100000));

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Silent segment should not affect duration',
      );
    });

    testWidgets('Merge video without audio (D) and video with audio (A)', (
      tester,
    ) async {
      final videoD = EditorVideo.asset(testDPath);
      final videoA = EditorVideo.asset(testAPath);

      final metadataD = await ProVideoEditor.instance.getMetadata(videoD);
      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);

      final expectedDuration = metadataD.duration + metadataA.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(video: videoD),
            VideoSegment(video: videoA),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
      );
    });

    testWidgets('Merge multiple videos without audio (D + D)', (tester) async {
      final videoD1 = EditorVideo.asset(testDPath);
      final videoD2 = EditorVideo.asset(testDPath);

      final metadataD = await ProVideoEditor.instance.getMetadata(videoD1);
      final expectedDuration = metadataD.duration * 2;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoD1),
            VideoSegment(video: videoD2),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Two silent videos should merge correctly',
      );
    });

    testWidgets('Merge with audio disabled', (tester) async {
      final videoA1 = EditorVideo.asset(testAPath);
      final videoA2 = EditorVideo.asset(testAPath);

      final metadataA = await ProVideoEditor.instance.getMetadata(videoA1);
      final expectedDuration = metadataA.duration * 2;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          enableAudio: false,
          videoSegments: [
            VideoSegment(video: videoA1),
            VideoSegment(video: videoA2),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Disabling audio should not affect duration',
      );
    });

    testWidgets('Merge audio/no-audio/audio (A + D + A)', (tester) async {
      final videoA1 = EditorVideo.asset(testAPath);
      final videoD = EditorVideo.asset(testDPath);
      final videoA2 = EditorVideo.asset(testAPath);

      final metadataA = await ProVideoEditor.instance.getMetadata(videoA1);
      final metadataD = await ProVideoEditor.instance.getMetadata(videoD);

      final expectedDuration =
          metadataA.duration + metadataD.duration + metadataA.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA1),
            VideoSegment(video: videoD),
            VideoSegment(video: videoA2),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Silent segment in middle should be handled correctly',
      );
    });

    testWidgets('Merge AAC audio (A) with AC3 audio (F)', (tester) async {
      final videoA = EditorVideo.asset(testAPath);
      final videoF = EditorVideo.asset(testFPath);

      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);
      final metadataF = await ProVideoEditor.instance.getMetadata(videoF);

      final expectedDuration = metadataA.duration + metadataF.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA),
            VideoSegment(video: videoF),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'AAC to AC3 audio codec transition should work',
      );
    }, skip: !enableMergeAudioTests);

    testWidgets('Merge AC3 audio (F) with AAC audio (A)', (tester) async {
      final videoF = EditorVideo.asset(testFPath);
      final videoA = EditorVideo.asset(testAPath);

      final metadataF = await ProVideoEditor.instance.getMetadata(videoF);
      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);

      final expectedDuration = metadataF.duration + metadataA.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoF),
            VideoSegment(video: videoA),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'AC3 to AAC audio codec transition should work',
      );
    }, skip: !enableMergeAudioTests);
  });

  group('Video Merging - Codec Compatibility', () {
    testWidgets('Merge H.264 (A) with HEVC (E)', (tester) async {
      final videoA = EditorVideo.asset(testAPath);
      final videoE = EditorVideo.asset(testEPath);

      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);
      final metadataE = await ProVideoEditor.instance.getMetadata(videoE);

      final expectedDuration = metadataA.duration + metadataE.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA),
            VideoSegment(video: videoE),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Different codecs should be handled correctly',
      );
    });

    testWidgets('Merge HEVC (E) with H.264 (A)', (tester) async {
      final videoE = EditorVideo.asset(testEPath);
      final videoA = EditorVideo.asset(testAPath);

      final metadataE = await ProVideoEditor.instance.getMetadata(videoE);
      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);

      final expectedDuration = metadataE.duration + metadataA.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoE),
            VideoSegment(video: videoA),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
      );
    });

    testWidgets('Merge multiple HEVC videos (E + E)', (tester) async {
      final videoE1 = EditorVideo.asset(testEPath);
      final videoE2 = EditorVideo.asset(testEPath);

      final metadataE = await ProVideoEditor.instance.getMetadata(videoE1);
      final expectedDuration = metadataE.duration * 2;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoE1),
            VideoSegment(video: videoE2),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'HEVC videos should merge correctly',
      );
    });
  });

  group('Video Merging - Complex Scenarios', () {
    testWidgets(
      'Merge all test videos (A + B + C + D + E + F)',
      (tester) async {
        final videoA = EditorVideo.asset(testAPath);
        final videoB = EditorVideo.asset(testBPath);
        final videoC = EditorVideo.asset(testCPath);
        final videoD = EditorVideo.asset(testDPath);
        final videoE = EditorVideo.asset(testEPath);
        final videoF = EditorVideo.asset(testFPath);

        final metadataA = await ProVideoEditor.instance.getMetadata(videoA);
        final metadataB = await ProVideoEditor.instance.getMetadata(videoB);
        final metadataC = await ProVideoEditor.instance.getMetadata(videoC);
        final metadataD = await ProVideoEditor.instance.getMetadata(videoD);
        final metadataE = await ProVideoEditor.instance.getMetadata(videoE);
        final metadataF = await ProVideoEditor.instance.getMetadata(videoF);

        final expectedDuration =
            metadataA.duration +
            metadataB.duration +
            metadataC.duration +
            metadataD.duration +
            metadataE.duration +
            metadataF.duration;

        final result = await ProVideoEditor.instance.renderVideo(
          VideoRenderData(
            outputFormat: VideoOutputFormat.mp4,
            videoSegments: [
              VideoSegment(video: videoA),
              VideoSegment(video: videoB),
              VideoSegment(video: videoC),
              VideoSegment(video: videoD),
              VideoSegment(video: videoE),
              VideoSegment(video: videoF),
            ],
          ),
        );

        expect(result, isNotNull);
        expect(result.lengthInBytes, greaterThan(100000));

        final outputMeta = await ProVideoEditor.instance.getMetadata(
          EditorVideo.memory(result),
        );

        expect(
          outputMeta.duration.inSeconds,
          closeTo(expectedDuration.inSeconds, durationTolerance * 2),
          reason: 'All test videos should merge into one',
        );
      },
      skip: !enableMergeAudioTests,
    );

    testWidgets('Merge with mixed trimming and full clips', (tester) async {
      final videoA = EditorVideo.asset(testAPath);
      final videoB = EditorVideo.asset(testBPath);
      final videoC = EditorVideo.asset(testCPath);

      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);
      final metadataB = await ProVideoEditor.instance.getMetadata(videoB);

      // A: full clip, B: trimmed, C: full clip
      const bTrimStart = Duration(seconds: 1);
      final bTrimEnd = Duration(seconds: metadataB.duration.inSeconds - 1);
      final bTrimmedDuration = bTrimEnd - bTrimStart;

      final metadataC = await ProVideoEditor.instance.getMetadata(videoC);
      final expectedDuration =
          metadataA.duration + bTrimmedDuration + metadataC.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA),
            VideoSegment(
              video: videoB,
              startTime: bTrimStart,
              endTime: bTrimEnd,
            ),
            VideoSegment(video: videoC),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Mixed trimming should work correctly',
      );
    });

    testWidgets(
      'Merge portrait/landscape/60fps/no-audio/HEVC (B + A + C + D + E)',
      (tester) async {
        final videoB = EditorVideo.asset(testBPath);
        final videoA = EditorVideo.asset(testAPath);
        final videoC = EditorVideo.asset(testCPath);
        final videoD = EditorVideo.asset(testDPath);
        final videoE = EditorVideo.asset(testEPath);

        final metadataB = await ProVideoEditor.instance.getMetadata(videoB);
        final metadataA = await ProVideoEditor.instance.getMetadata(videoA);
        final metadataC = await ProVideoEditor.instance.getMetadata(videoC);
        final metadataD = await ProVideoEditor.instance.getMetadata(videoD);
        final metadataE = await ProVideoEditor.instance.getMetadata(videoE);

        final expectedDuration =
            metadataB.duration +
            metadataA.duration +
            metadataC.duration +
            metadataD.duration +
            metadataE.duration;

        final result = await ProVideoEditor.instance.renderVideo(
          VideoRenderData(
            outputFormat: VideoOutputFormat.mp4,
            videoSegments: [
              VideoSegment(video: videoB),
              VideoSegment(video: videoA),
              VideoSegment(video: videoC),
              VideoSegment(video: videoD),
              VideoSegment(video: videoE),
            ],
          ),
        );

        expect(result, isNotNull);

        final outputMeta = await ProVideoEditor.instance.getMetadata(
          EditorVideo.memory(result),
        );

        expect(
          outputMeta.duration.inSeconds,
          closeTo(expectedDuration.inSeconds, durationTolerance * 2),
          reason:
              'Complex scenario with all variations should produce '
              'valid output',
        );
      },
    );
  });

  group('Video Merging - Output Formats', () {
    final tempFiles = <String>[];

    tearDownAll(() {
      // Cleanup all temporary test files
      for (final path in tempFiles) {
        final file = File(path);
        if (file.existsSync()) {
          file.deleteSync();
        }
      }
    });

    testWidgets('Merge videos to MP4 format', (tester) async {
      final videoA1 = EditorVideo.asset(testAPath);
      final videoA2 = EditorVideo.asset(testAPath);

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoA1),
            VideoSegment(video: videoA2),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(outputMeta.extension, equals('mp4'));
    });

    testWidgets('Merge videos to MOV format (Apple)', (tester) async {
      final videoA1 = EditorVideo.asset(testAPath);
      final videoA2 = EditorVideo.asset(testBPath);

      final outputPath =
          '${Directory.systemTemp.path}/test_merge_${DateTime.now().millisecondsSinceEpoch}.mov';
      tempFiles.add(outputPath);

      await ProVideoEditor.instance.renderVideoToFile(
        outputPath,
        VideoRenderData(
          outputFormat: VideoOutputFormat.mov,
          videoSegments: [
            VideoSegment(video: videoA1),
            VideoSegment(video: videoA2),
          ],
        ),
      );

      final outputFile = File(outputPath);
      expect(outputFile.existsSync(), isTrue);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.file(outputPath),
      );

      expect(
        outputMeta.extension,
        anyOf(equals('mov'), equals('quicktime')),
        reason: 'MOV format can be reported as either "mov" or "quicktime"',
      );
    }, skip: !isIOS && !isMacOS);
  });

  group('Video Merging - Edge Cases', () {
    // Output file path for large 4K test
    final test4kOutputPath = '${Directory.systemTemp.path}/test_4k_merge.mp4';

    tearDownAll(() {
      // Cleanup large test output files
      final outputFile = File(test4kOutputPath);
      if (outputFile.existsSync()) {
        outputFile.deleteSync();
      }
    });

    testWidgets('Merge with very short trim duration', (tester) async {
      final videoA1 = EditorVideo.asset(testAPath);
      final videoA2 = EditorVideo.asset(testAPath);

      // Trim to only 0.5 seconds
      const trimStart = Duration(seconds: 1);
      const trimEnd = Duration(milliseconds: 1500);

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(
              video: videoA1,
              startTime: trimStart,
              endTime: trimEnd,
            ),
            VideoSegment(video: videoA2),
          ],
        ),
      );

      expect(result, isNotNull);
      expect(
        result.lengthInBytes,
        greaterThan(10000),
        reason: 'Even very short clips should produce valid output',
      );
    });

    testWidgets('Merge same video multiple times', (tester) async {
      final videoA = EditorVideo.asset(testAPath);
      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);
      const repeatCount = 5;
      final expectedDuration = metadataA.duration * repeatCount;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: List.generate(
            repeatCount,
            (_) => VideoSegment(video: EditorVideo.asset(testAPath)),
          ),
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Repeated clips should have correct total duration',
      );
    });

    testWidgets('Merge large 4K files (~1GB total)', (tester) async {
      final video4kA = EditorVideo.asset(test4kAPath);
      final video4kB = EditorVideo.asset(test4kBPath);

      const loopCount = 10;

      final metadata4kA = await ProVideoEditor.instance.getMetadata(video4kA);
      final metadata4kB = await ProVideoEditor.instance.getMetadata(video4kB);

      final expectedDuration =
          (metadata4kA.duration + metadata4kB.duration) * loopCount;

      final outputPath = await ProVideoEditor.instance.renderVideoToFile(
        test4kOutputPath,
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            for (int i = 0; i < loopCount; i++) ...[
              VideoSegment(video: video4kA),
              VideoSegment(video: video4kB),
            ],
          ],
        ),
      );

      expect(outputPath, isNotNull);
      final outputFile = File(outputPath);
      expect(outputFile.existsSync(), isTrue);
      expect(
        outputFile.lengthSync(),
        greaterThan(100000000),
        reason: 'Large merged file should be substantial',
      );

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.file(outputPath),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Duration should match sum of input durations',
      );
      expect(outputMeta.extension, equals('mp4'));
    }, skip: !enable4kTests);
  });

  group('Video Merging - Progress Reporting', () {
    testWidgets('Merge emits progress updates', (tester) async {
      final videoA1 = EditorVideo.asset(testAPath);
      final videoA2 = EditorVideo.asset(testAPath);
      final videoA3 = EditorVideo.asset(testAPath);

      final task = VideoRenderData(
        outputFormat: VideoOutputFormat.mp4,
        videoSegments: [
          VideoSegment(video: videoA1),
          VideoSegment(video: videoA2),
          VideoSegment(video: videoA3),
        ],
      );

      final progressValues = <double>[];
      final sub = task.progressStream.listen((event) {
        progressValues.add(event.progress);
      });

      await ProVideoEditor.instance.renderVideo(task);
      await sub.cancel();

      expect(
        progressValues,
        isNotEmpty,
        reason: 'Progress updates should be emitted',
      );
      expect(
        progressValues.first,
        lessThanOrEqualTo(0.1),
        reason: 'Progress should start near 0',
      );
      expect(
        progressValues.last,
        closeTo(1.0, 0.05),
        reason: 'Progress should reach 1.0 at completion',
      );

      // Verify progress is monotonically increasing
      for (int i = 1; i < progressValues.length; i++) {
        expect(
          progressValues[i],
          greaterThanOrEqualTo(progressValues[i - 1]),
          reason: 'Progress should not decrease',
        );
      }
    });
  });

  group('Video Merging - Rotation Metadata', () {
    testWidgets('Merge video with rotation metadata (B) with baseline (A)', (
      tester,
    ) async {
      final videoB = EditorVideo.asset(testBPath); // Has rotation metadata
      final videoA = EditorVideo.asset(testAPath);

      final metadataB = await ProVideoEditor.instance.getMetadata(videoB);
      final metadataA = await ProVideoEditor.instance.getMetadata(videoA);

      final expectedDuration = metadataB.duration + metadataA.duration;

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: videoB),
            VideoSegment(video: videoA),
          ],
        ),
      );

      expect(result, isNotNull);

      final outputMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );

      expect(
        outputMeta.duration.inSeconds,
        closeTo(expectedDuration.inSeconds, durationTolerance),
        reason: 'Rotation metadata should not affect duration',
      );
    });
  });
}
