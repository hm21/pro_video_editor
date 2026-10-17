import 'dart:typed_data';
import 'dart:ui' show Size, instantiateImageCodec;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final inputVideo = EditorVideo.asset(kVideoEditorExampleH264Path);

  // Each demo clip is 5s; transitions use a fixed 800ms / 700ms duration.
  const clipDuration = Duration(seconds: 5);
  const overlapDuration = Duration(milliseconds: 800);
  const dipDuration = Duration(milliseconds: 700);

  // Generous tolerance — encoder/frame rounding and the pre-render duration
  // estimate can shift the result by a few frames.
  const durationTolerance = 0.6; // seconds

  /// Renders [model] and asserts a non-trivial, correctly-formatted result.
  Future<VideoMetadata> render(
    String description,
    VideoRenderData model,
  ) async {
    final result = await ProVideoEditor.instance.renderVideo(model);
    expect(result, isNotNull, reason: '$description — result is null');
    expect(
      result.lengthInBytes,
      greaterThan(100000),
      reason: '$description — video is too small',
    );

    final meta = await ProVideoEditor.instance.getMetadata(
      EditorVideo.memory(result),
    );
    expect(
      meta.extension,
      equals(model.outputFormat.name),
      reason: '$description — wrong format',
    );
    return meta;
  }

  /// Two 5s clips with [transition] applied between them.
  VideoRenderData twoClips(ClipTransition transition) => VideoRenderData(
    outputFormat: VideoOutputFormat.mp4,
    videoSegments: [
      VideoSegment(
        video: inputVideo,
        startTime: Duration.zero,
        endTime: clipDuration,
        transition: transition,
      ),
      VideoSegment(
        video: inputVideo,
        startTime: const Duration(seconds: 10),
        endTime: const Duration(seconds: 15),
      ),
    ],
  );

  void expectDuration(VideoMetadata meta, Duration expected, String reason) {
    expect(
      meta.duration.inMilliseconds / 1000,
      closeTo(expected.inMilliseconds / 1000, durationTolerance),
      reason: reason,
    );
  }

  // ───────────────────────────────────────────────────────────
  // Overlap transitions — blend the clips and shorten the output
  // ───────────────────────────────────────────────────────────
  group('Clip transitions — overlap (shorten timeline)', () {
    final overlapTypes = ClipTransitionType.values.where(
      (type) => type.isOverlap,
    );

    for (final type in overlapTypes) {
      testWidgets(type.name, (_) async {
        final meta = await render(
          type.name,
          twoClips(ClipTransition(type: type, duration: overlapDuration)),
        );
        // Two 5s clips overlapping by 800ms → ~9.2s.
        expectDuration(
          meta,
          clipDuration * 2 - overlapDuration,
          '${type.name} should overlap and shorten the output',
        );
      });
    }
  });

  // ───────────────────────────────────────────────────────────
  // Dip transitions — dip through a color, duration unchanged
  // ───────────────────────────────────────────────────────────
  group('Clip transitions — dip (keep duration)', () {
    final dipTypes = ClipTransitionType.values.where((type) => type.isDip);

    for (final type in dipTypes) {
      testWidgets(type.name, (_) async {
        final meta = await render(
          type.name,
          twoClips(ClipTransition(type: type, duration: dipDuration)),
        );
        // Dip happens within the clips' own time → ~10s.
        expectDuration(
          meta,
          clipDuration * 2,
          '${type.name} should keep the total duration',
        );
      });
    }
  });

  // ───────────────────────────────────────────────────────────
  // Directional transitions × all directions
  // ───────────────────────────────────────────────────────────
  group('Clip transitions — directions', () {
    final directionalTypes = ClipTransitionType.values.where(
      (type) => type.usesDirection,
    );

    for (final type in directionalTypes) {
      for (final dir in ClipTransitionDirection.values) {
        testWidgets('${type.name} / ${dir.name}', (_) async {
          await render(
            '${type.name} ${dir.name}',
            twoClips(
              ClipTransition(
                type: type,
                duration: overlapDuration,
                direction: dir,
              ),
            ),
          );
        });
      }
    }
  });

  // ───────────────────────────────────────────────────────────
  // All easing curves (driven on a dissolve)
  // ───────────────────────────────────────────────────────────
  group('Clip transitions — easing curves', () {
    for (final curve in AnimationCurve.values) {
      testWidgets('dissolve curve: ${curve.name}', (_) async {
        await render(
          'dissolve ${curve.name}',
          twoClips(
            ClipTransition(
              type: ClipTransitionType.dissolve,
              duration: overlapDuration,
              curve: curve,
            ),
          ),
        );
      });
    }
  });

  // ───────────────────────────────────────────────────────────
  // Per-segment playback speed × transitions
  //
  // Regression guard: per-clip `playbackSpeed` must be applied to the footage
  // that participates in a transition. The blend duration is interpreted in
  // output (post-speed) time, so each side consumes `output × speed` of source.
  // ───────────────────────────────────────────────────────────
  group('Clip transitions — playback speed', () {
    // Output seconds of a single 5s source clip at [speed].
    double clipOutSeconds(double speed) =>
        clipDuration.inMilliseconds / 1000 / speed;

    /// Two 5s source clips with a [transition] and independent per-clip speeds.
    VideoRenderData twoClipsSpeed(
      ClipTransition transition, {
      required double speed1,
      required double speed2,
    }) => VideoRenderData(
      outputFormat: VideoOutputFormat.mp4,
      videoSegments: [
        VideoSegment(
          video: inputVideo,
          startTime: Duration.zero,
          endTime: clipDuration,
          playbackSpeed: speed1,
          transition: transition,
        ),
        VideoSegment(
          video: inputVideo,
          startTime: const Duration(seconds: 10),
          endTime: const Duration(seconds: 15),
          playbackSpeed: speed2,
        ),
      ],
    );

    for (final speed in [2.0, 0.5]) {
      testWidgets('dissolve @ ${speed}x — overlap shortens, footage sped', (
        _,
      ) async {
        final meta = await render(
          'dissolve ${speed}x',
          twoClipsSpeed(
            const ClipTransition(
              type: ClipTransitionType.dissolve,
              duration: overlapDuration,
            ),
            speed1: speed,
            speed2: speed,
          ),
        );
        // Both clips sped to 5/s, overlapping by the output-time transition.
        // (At 2× this is ~4.2s — clearly distinct from the unfixed 5.0s
        //  dropped-transition or 9.2s speed-ignored results.)
        final expected = Duration(
          milliseconds:
              (2 * clipOutSeconds(speed) * 1000 -
                      overlapDuration.inMilliseconds)
                  .round(),
        );
        expectDuration(
          meta,
          expected,
          'dissolve @ ${speed}x: footage must be sped AND overlapped',
        );
      });

      testWidgets('fadeToBlack @ ${speed}x — dip keeps speed-adjusted length', (
        _,
      ) async {
        final meta = await render(
          'fadeToBlack ${speed}x',
          twoClipsSpeed(
            const ClipTransition(
              type: ClipTransitionType.fadeToBlack,
              duration: dipDuration,
            ),
            speed1: speed,
            speed2: speed,
          ),
        );
        // Dip does not shorten; the total is just both clips sped to 5/s.
        final expected = Duration(
          milliseconds: (2 * clipOutSeconds(speed) * 1000).round(),
        );
        expectDuration(
          meta,
          expected,
          'fadeToBlack @ ${speed}x: total must reflect per-clip speed',
        );
      });
    }

    testWidgets('dissolve with mixed speeds (outgoing 2× · incoming 0.5×)', (
      _,
    ) async {
      final meta = await render(
        'dissolve mixed-speed',
        twoClipsSpeed(
          const ClipTransition(
            type: ClipTransitionType.dissolve,
            duration: overlapDuration,
          ),
          speed1: 2.0,
          speed2: 0.5,
        ),
      );
      // clip1 → 2.5s, clip2 → 10s, overlapping by 0.8s → ~11.7s. Each side is
      // time-scaled with its own factor across a single output-time blend.
      final expected = Duration(
        milliseconds:
            (clipOutSeconds(2.0) * 1000 +
                    clipOutSeconds(0.5) * 1000 -
                    overlapDuration.inMilliseconds)
                .round(),
      );
      expectDuration(
        meta,
        expected,
        'mixed-speed dissolve: each side must keep its own speed',
      );
    });
  });

  // ───────────────────────────────────────────────────────────
  // Combined: dissolve → fade-to-black across three clips
  // ───────────────────────────────────────────────────────────
  group('Clip transitions — combined', () {
    testWidgets('dissolve then fade-to-black across 3 clips', (_) async {
      final meta = await render(
        'combined',
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(
              video: inputVideo,
              startTime: Duration.zero,
              endTime: clipDuration,
              transition: const ClipTransition(
                type: ClipTransitionType.dissolve,
                duration: overlapDuration,
                curve: AnimationCurve.easeInOut,
              ),
            ),
            VideoSegment(
              video: inputVideo,
              startTime: const Duration(seconds: 8),
              endTime: const Duration(seconds: 13),
              transition: const ClipTransition(
                type: ClipTransitionType.fadeToBlack,
                duration: Duration(milliseconds: 600),
              ),
            ),
            VideoSegment(
              video: inputVideo,
              startTime: const Duration(seconds: 15),
              endTime: const Duration(seconds: 20),
            ),
          ],
        ),
      );
      // 3×5s, one overlap dissolve (-800ms); the fade-to-black keeps duration.
      expectDuration(
        meta,
        clipDuration * 3 - overlapDuration,
        'combined transitions duration mismatch',
      );
    });
  });

  // ───────────────────────────────────────────────────────────
  // Loop wrap — a transition on the last/only segment wraps into the first
  // ───────────────────────────────────────────────────────────
  group('Clip transitions — loop wrap', () {
    testWidgets('overlap on the only segment shortens like a wrap', (_) async {
      final meta = await render(
        'single-segment-loop-wrap',
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(
              video: inputVideo,
              startTime: Duration.zero,
              endTime: clipDuration,
              transition: const ClipTransition(
                type: ClipTransitionType.dissolve,
                duration: overlapDuration,
              ),
            ),
          ],
        ),
      );
      // The end cross-dissolves into the start → output shortened by the
      // overlap duration, exactly like an overlap between two clips.
      expectDuration(
        meta,
        clipDuration - overlapDuration,
        'a dissolve on the only segment must wrap and shorten the output',
      );
    });

    testWidgets('dip on the only segment keeps the duration', (_) async {
      final meta = await render(
        'single-segment-dip-wrap',
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(
              video: inputVideo,
              startTime: Duration.zero,
              endTime: clipDuration,
              transition: const ClipTransition(
                type: ClipTransitionType.fadeToBlack,
                duration: dipDuration,
              ),
            ),
          ],
        ),
      );
      // Dip wrap fades out at the end and in at the start → length unchanged.
      expectDuration(
        meta,
        clipDuration,
        'a dip wrap must not change the duration',
      );
    });

    testWidgets('wrap is skipped when the clip is too short', (_) async {
      // A 1s clip with an 800ms wrap: head + tail (1.6s) exceed the source, so
      // no middle body remains → wrap skipped → full clip duration.
      final meta = await render(
        'single-segment-wrap-too-short',
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(
              video: inputVideo,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 1),
              transition: const ClipTransition(
                type: ClipTransitionType.dissolve,
                duration: overlapDuration,
              ),
            ),
          ],
        ),
      );
      expectDuration(
        meta,
        const Duration(seconds: 1),
        'too-short clip must fall back to no wrap (full duration)',
      );
    });
  });

  // ───────────────────────────────────────────────────────────
  // Render end — blends that would start after endTime are left out
  // ───────────────────────────────────────────────────────────
  group('Clip transitions — render end', () {
    const windowDuration = Duration(seconds: 2);
    const endTime = Duration(seconds: 3);
    const dissolve = ClipTransition(
      type: ClipTransitionType.dissolve,
      duration: overlapDuration,
    );

    /// [count] 2 s windows of the demo clip, each dissolving into the next;
    /// the last one into the first when [loop] is set.
    List<VideoSegment> windows(int count, {bool loop = false}) => [
      for (var i = 0; i < count; i++)
        VideoSegment(
          video: inputVideo,
          startTime: windowDuration * (i % 5),
          endTime: windowDuration * (i % 5 + 1),
          transition: i < count - 1 || loop ? dissolve : null,
        ),
    ];

    testWidgets('a long timeline stops at the end time', (_) async {
      // Only the first two of the 19 blends start before 3 s.
      final meta = await render(
        'long-timeline-render-end',
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: windows(20),
          endTime: endTime,
        ),
      );
      expectDuration(meta, endTime, 'the output must stop at the end time');
    });

    testWidgets('a loop wrap after the end time still stops there', (_) async {
      final meta = await render(
        'loop-wrap-render-end',
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: windows(20, loop: true),
          endTime: endTime,
        ),
      );
      expectDuration(meta, endTime, 'the output must stop at the end time');
    });

    testWidgets('a clip whose container outlasts its video keeps the blend '
        'after it', (_) async {
      // demo_world.mp4's container runs ~0.5 s past its last frame, and the
      // render plays the clip only up to that frame. The dissolve after it
      // starts at ~2.23 s, so a 2.6 s end shows its first third, exactly as a
      // longer render does.
      Future<Uint8List> renderUntil(Duration end) async {
        final result = await ProVideoEditor.instance.renderVideo(
          VideoRenderData(
            outputFormat: VideoOutputFormat.mp4,
            videoSegments: [
              VideoSegment(
                video: EditorVideo.asset(kVideoEditorExampleAssetWorldPath),
                startTime: const Duration(seconds: 29),
              ),
              VideoSegment(
                video: inputVideo,
                startTime: Duration.zero,
                endTime: windowDuration,
                transition: dissolve,
              ),
              VideoSegment(
                video: inputVideo,
                startTime: const Duration(seconds: 10),
                endTime: const Duration(seconds: 12),
              ),
            ],
            endTime: end,
          ),
        );
        expect(result.lengthInBytes, greaterThan(10000));
        return result;
      }

      Future<ByteData> frameAt(Uint8List video, Duration at) async {
        final thumbnails = await ProVideoEditor.instance.getThumbnails(
          ThumbnailConfigs(
            video: EditorVideo.memory(video),
            outputFormat: ThumbnailFormat.png,
            timestamps: [at],
            outputSize: const Size(160, 90),
            boxFit: ThumbnailBoxFit.cover,
          ),
        );
        expect(thumbnails, isNotEmpty, reason: 'no frame at $at');
        final codec = await instantiateImageCodec(thumbnails.first);
        final image = (await codec.getNextFrame()).image;
        return (await image.toByteData())!;
      }

      const sampleAt = Duration(milliseconds: 2500);
      final short = await frameAt(
        await renderUntil(const Duration(milliseconds: 2600)),
        sampleAt,
      );
      final long = await frameAt(
        await renderUntil(const Duration(milliseconds: 3400)),
        sampleAt,
      );

      var difference = 0;
      for (var i = 0; i < short.lengthInBytes; i += 4) {
        for (var channel = 0; channel < 3; channel++) {
          difference +=
              (short.getUint8(i + channel) - long.getUint8(i + channel)).abs();
        }
      }
      final meanDifference = difference / (short.lengthInBytes / 4 * 3);
      expect(
        meanDifference,
        lessThan(4),
        reason: 'the frame at $sampleAt must show the dissolve in both renders',
      );
    });

    testWidgets('a clip whose container outlasts its video blends with every '
        'overlap type', (_) async {
      // The blend's outgoing side reaches into the last ~0.5 s of
      // demo_world.mp4, which holds no video. iOS and macOS drew the newer
      // types with nothing there and fell back to a hard cut, which runs
      // longer than the dissolve.
      Future<double> secondsWith(ClipTransitionType type) async {
        final result = await ProVideoEditor.instance.renderVideo(
          VideoRenderData(
            outputFormat: VideoOutputFormat.mp4,
            videoSegments: [
              VideoSegment(
                video: EditorVideo.asset(kVideoEditorExampleAssetWorldPath),
                startTime: const Duration(seconds: 29),
                transition: ClipTransition(
                  type: type,
                  duration: overlapDuration,
                ),
              ),
              VideoSegment(
                video: inputVideo,
                startTime: Duration.zero,
                endTime: windowDuration,
              ),
            ],
          ),
        );
        final meta = await ProVideoEditor.instance.getMetadata(
          EditorVideo.memory(result),
        );
        return meta.duration.inMilliseconds / 1000;
      }

      final dissolveSeconds = await secondsWith(ClipTransitionType.dissolve);
      for (final type in ClipTransitionType.values.where((t) => t.isOverlap)) {
        expect(
          await secondsWith(type),
          closeTo(dissolveSeconds, 0.1),
          reason: '${type.name} must blend like the dissolve, not cut',
        );
      }
    });
  });

  // ───────────────────────────────────────────────────────────
  // Trimmed HDR source — iOS/macOS pre-transcode only each segment's window
  // and blend on the shorter files that come out of it
  // ───────────────────────────────────────────────────────────
  group('Clip transitions — trimmed HDR source', () {
    final hdrVideo = EditorVideo.asset(kVideoEditorExampleHevcPath);
    // The pre-transcode is Darwin-only; other platforms render HDR directly.
    final skipPlatform =
        defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS;
    // Tighter than [durationTolerance]: a blend computed on the windows of the
    // source instead of the trimmed files misses by a second or more.
    const tolerance = 0.25;

    testWidgets('dissolve between two windows of one source', (_) async {
      final meta = await render(
        'hdr-trimmed-dissolve',
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(
              video: hdrVideo,
              startTime: const Duration(milliseconds: 500),
              endTime: const Duration(milliseconds: 2000),
              transition: const ClipTransition(
                type: ClipTransitionType.dissolve,
                duration: Duration(milliseconds: 500),
              ),
            ),
            VideoSegment(
              video: hdrVideo,
              startTime: const Duration(milliseconds: 2500),
              endTime: const Duration(milliseconds: 4000),
            ),
          ],
        ),
      );
      // Two 1.5 s windows overlapping by 500 ms → 2.5 s; a hard cut would
      // keep 3 s.
      expect(meta.duration.inMilliseconds / 1000, closeTo(2.5, tolerance));
    }, skip: skipPlatform);

    testWidgets('dissolve wrap on a trimmed segment', (_) async {
      final meta = await render(
        'hdr-trimmed-wrap',
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(
              video: hdrVideo,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 3),
              transition: const ClipTransition(
                type: ClipTransitionType.dissolve,
                duration: Duration(milliseconds: 500),
              ),
            ),
          ],
        ),
      );
      // A 2 s window whose end wraps into its start by 500 ms → 1.5 s.
      expect(meta.duration.inMilliseconds / 1000, closeTo(1.5, tolerance));
    }, skip: skipPlatform);
  });
}
