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
    const overlapTypes = [
      ClipTransitionType.dissolve,
      ClipTransitionType.slide,
      ClipTransitionType.push,
      ClipTransitionType.wipe,
    ];

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
    const dipTypes = [
      ClipTransitionType.fadeToBlack,
      ClipTransitionType.fadeToWhite,
    ];

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
    const directionalTypes = [
      ClipTransitionType.slide,
      ClipTransitionType.push,
      ClipTransitionType.wipe,
    ];

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
}
