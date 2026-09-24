import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Size, instantiateImageCodec;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// Integration tests for the multi-layer [VideoComposition] render path.
///
/// These assert render success plus the composition-specific invariants that
/// can be checked from output metadata: the output resolution follows the
/// composition canvas, and the output duration follows the layered timeline
/// (clip trims, multi-clip layers and `timelineStart` offsets).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  // Shared test assets (see integration_test.md).
  const testAPath = 'assets/tests/test_a.mp4'; // 1920x1080, 30fps, H.264, AAC
  const testBPath = 'assets/tests/test_b.mp4'; // 720x1280 stored portrait
  const testDPath = 'assets/tests/test_d.mp4'; // 1920x1080, 30fps, no audio
  // 640x360 flagged -90° like a phone recording, so it shows 360x640.
  const testGPath = 'assets/tests/test_g.mp4';
  // HEVC Main 10, HLG/BT.2020, 1920x1080 flagged -90°, so it shows 1080x1920.
  const hevcPath = 'assets/hevc.mp4';

  const durationTolerance = 0.3; // seconds
  const sizeTolerance = 4.0; // pixels (encoders round to even dimensions)

  Future<VideoMetadata> meta(String path) =>
      pve.getMetadata(EditorVideo.asset(path));

  void expectResolution(VideoMetadata out, Size expected) {
    expect(out.resolution.width, closeTo(expected.width, sizeTolerance));
    expect(out.resolution.height, closeTo(expected.height, sizeTolerance));
  }

  /// Decodes the frame of [video] at [at], or returns null if none could be
  /// extracted (some devices cannot thumbnail 10-bit HDR HEVC).
  ///
  /// The frame is requested at [size] with `cover`; with [size] in the video's
  /// own aspect ratio there is no crop, so relative positions map directly onto
  /// the video frame.
  Future<_Frame?> tryFrameOf(
    EditorVideo video,
    Size size, {
    Duration at = const Duration(milliseconds: 400),
  }) async {
    final frames = await pve.getThumbnails(
      ThumbnailConfigs(
        video: video,
        outputFormat: ThumbnailFormat.png,
        timestamps: [at],
        outputSize: size,
        boxFit: ThumbnailBoxFit.cover,
      ),
    );
    if (frames.isEmpty) return null;
    final codec = await instantiateImageCodec(frames.first);
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData();
    return _Frame(data!, image.width, image.height);
  }

  Future<_Frame> frameOf(
    EditorVideo video,
    Size size, {
    Duration at = const Duration(milliseconds: 400),
  }) async {
    final frame = await tryFrameOf(video, size, at: at);
    expect(frame, isNotNull, reason: 'No frame extracted from the output');
    return frame!;
  }

  /// Decodes a frame of the rendered [video] at [at] and returns the RGBA of
  /// the pixel at the relative position ([fx], [fy]) in `0..1`.
  ///
  /// The output resolution is the [canvas] size, so the relative position maps
  /// directly onto the composition canvas.
  Future<List<int>> samplePixel(
    Uint8List video,
    Size canvas,
    double fx,
    double fy, {
    Duration at = const Duration(milliseconds: 400),
  }) async {
    final frame = await frameOf(EditorVideo.memory(video), canvas, at: at);
    return frame.at(fx, fy);
  }

  /// Sum of absolute per-channel (RGB) differences between two pixels.
  int colorDist(List<int> a, List<int> b) =>
      (a[0] - b[0]).abs() + (a[1] - b[1]).abs() + (a[2] - b[2]).abs();

  /// Whether a pixel is clearly the red background (tolerant of YUV rounding).
  bool isRed(List<int> c) => c[0] > 150 && c[1] < 90 && c[2] < 90;

  /// Sample points off both centre axes, where a pixel would map onto itself
  /// under a half turn or a mirror.
  const offAxisPoints = <Offset>[
    Offset(0.15, 0.2),
    Offset(0.35, 0.2),
    Offset(0.65, 0.2),
    Offset(0.85, 0.2),
    Offset(0.15, 0.4),
    Offset(0.35, 0.4),
    Offset(0.65, 0.4),
    Offset(0.85, 0.4),
    Offset(0.15, 0.6),
    Offset(0.35, 0.6),
    Offset(0.65, 0.6),
    Offset(0.85, 0.6),
    Offset(0.15, 0.8),
    Offset(0.35, 0.8),
    Offset(0.65, 0.8),
    Offset(0.85, 0.8),
  ];

  /// Expects the strip of [out] from the relative x [left] over [width] to
  /// show [source] upright: closer to it than to its half turn, which is what
  /// a clip flagged ±90° shows when the flag turns it the wrong way, and than
  /// to its mirror image.
  void expectUpright(
    _Frame out,
    _Frame source, {
    double left = 0,
    double width = 1,
  }) {
    int distance(Offset Function(Offset p) map) {
      var sum = 0;
      for (final p in offAxisPoints) {
        final s = map(p);
        sum += colorDist(
          out.at(left + p.dx * width, p.dy),
          source.at(s.dx, s.dy),
        );
      }
      return sum;
    }

    final upright = distance((p) => p);
    final turned = distance((p) => Offset(1 - p.dx, 1 - p.dy));
    final mirrored = distance((p) => Offset(1 - p.dx, p.dy));
    expect(
      upright,
      lessThan(turned),
      reason:
          'Layer at x=$left is upside down: $turned off its source turned '
          'half-way, $upright off it upright',
    );
    expect(
      upright,
      lessThan(mirrored),
      reason:
          'Layer at x=$left is mirrored: $mirrored off its source mirrored, '
          '$upright off it upright',
    );
  }

  group('Composition - Basics', () {
    testWidgets('single full-canvas layer renders at canvas size', (
      tester,
    ) async {
      final m = await meta(testAPath);

      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: m.resolution,
            layers: [
              VideoLayer(
                clips: [VideoSegment(video: EditorVideo.asset(testAPath))],
              ),
            ],
          ),
        ),
      );

      expect(result, isNotNull);
      expect(result.lengthInBytes, greaterThan(50000));

      final out = await pve.getMetadata(EditorVideo.memory(result));
      expectResolution(out, m.resolution);
      expect(
        out.duration.inSeconds,
        closeTo(m.duration.inSeconds, durationTolerance),
        reason: 'A single full-length layer keeps the source duration',
      );
      expect(out.extension, equals('mp4'));
    });

    testWidgets('explicit canvasSize drives output resolution', (tester) async {
      const canvas = Size(1280, 720);

      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: canvas,
            layers: [
              VideoLayer(
                clips: [VideoSegment(video: EditorVideo.asset(testAPath))],
              ),
            ],
          ),
        ),
      );

      final out = await pve.getMetadata(EditorVideo.memory(result));
      expectResolution(out, canvas);
    });
  });

  group('Composition - Timeline', () {
    testWidgets('timelineStart on a layer extends total duration', (
      tester,
    ) async {
      final m = await meta(testAPath);
      const shift = Duration(seconds: 2);

      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: m.resolution,
            layers: [
              // Base, full length: 0 .. D
              VideoLayer(
                clips: [VideoSegment(video: EditorVideo.asset(testAPath))],
              ),
              // Overlay shifted to start at +2s: 2 .. 2+D (drives the total)
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testAPath),
                    timelineStart: shift,
                  ),
                ],
                transform: const SegmentTransform(
                  offset: Offset(20, 20),
                  size: Size(320, 180),
                ),
              ),
            ],
          ),
        ),
      );

      final out = await pve.getMetadata(EditorVideo.memory(result));
      final expected = m.duration + shift;
      expect(
        out.duration.inSeconds,
        closeTo(expected.inSeconds, durationTolerance),
        reason: 'timelineStart should push the composition end out',
      );
    });

    testWidgets('multi-clip layer concatenates clip durations', (tester) async {
      // Two back-to-back 3s trims on one layer => 6s. Both trims stay within
      // the ~5s source.
      const clip = Duration(seconds: 3);

      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: const Size(1280, 720),
            layers: [
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testAPath),
                    startTime: Duration.zero,
                    endTime: clip,
                  ),
                  VideoSegment(
                    video: EditorVideo.asset(testAPath),
                    startTime: const Duration(seconds: 2),
                    endTime: const Duration(seconds: 5),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      final out = await pve.getMetadata(EditorVideo.memory(result));
      expect(
        out.duration.inSeconds,
        closeTo((clip * 2).inSeconds, durationTolerance),
        reason: 'Clips on a layer play sequentially',
      );
    });

    testWidgets('trimmed clip controls duration', (tester) async {
      const trimmed = Duration(seconds: 4);

      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: const Size(1280, 720),
            layers: [
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testAPath),
                    startTime: const Duration(seconds: 1),
                    endTime: const Duration(seconds: 5),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      final out = await pve.getMetadata(EditorVideo.memory(result));
      expect(
        out.duration.inSeconds,
        closeTo(trimmed.inSeconds, durationTolerance),
      );
    });

    testWidgets('global startTime/endTime trims the whole composition', (
      tester,
    ) async {
      // Both bounds stay within the ~5s source so the explicit end (not the
      // composition length) is what bounds the output.
      const start = Duration(seconds: 1);
      const end = Duration(seconds: 4);
      final m = await meta(testAPath);

      final result = await pve.renderVideo(
        VideoRenderData(
          startTime: start,
          endTime: end,
          composition: VideoComposition(
            canvasSize: m.resolution,
            layers: [
              VideoLayer(
                clips: [VideoSegment(video: EditorVideo.asset(testAPath))],
              ),
            ],
          ),
        ),
      );

      final out = await pve.getMetadata(EditorVideo.memory(result));
      expect(
        out.duration.inSeconds,
        closeTo((end - start).inSeconds, durationTolerance),
        reason: 'Global trim should bound the composition duration',
      );
    });
  });

  group('Composition - Layouts', () {
    testWidgets('picture-in-picture renders at base resolution', (
      tester,
    ) async {
      final m = await meta(testAPath);

      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: m.resolution,
            layers: [
              VideoLayer(
                clips: [VideoSegment(video: EditorVideo.asset(testAPath))],
              ),
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testAPath),
                    endTime: const Duration(seconds: 4),
                    volume: 0,
                  ),
                ],
                transform: SegmentTransform(
                  offset: const Offset(24, 24),
                  size: Size(m.resolution.width / 3, m.resolution.height / 3),
                  fit: SegmentFit.cover,
                ),
              ),
            ],
          ),
        ),
      );

      expect(result, isNotNull);
      final out = await pve.getMetadata(EditorVideo.memory(result));
      expectResolution(out, m.resolution);
    });

    testWidgets('vertical stack uses a tall canvas', (tester) async {
      final m = await meta(testAPath);
      final canvas = Size(m.resolution.width, m.resolution.height * 2);
      const half = Duration(seconds: 4);

      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: canvas,
            layers: [
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testAPath),
                    endTime: half,
                  ),
                ],
                transform: SegmentTransform(
                  offset: Offset.zero,
                  size: m.resolution,
                ),
              ),
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testBPath),
                    endTime: half,
                    volume: 0,
                  ),
                ],
                transform: SegmentTransform(
                  offset: Offset(0, m.resolution.height),
                  size: m.resolution,
                ),
              ),
            ],
          ),
        ),
      );

      expect(result, isNotNull);
      final out = await pve.getMetadata(EditorVideo.memory(result));
      expectResolution(out, canvas);
    });

    testWidgets('2x2 grid renders', (tester) async {
      final m = await meta(testAPath);
      final cell = Size(m.resolution.width / 2, m.resolution.height / 2);

      VideoLayer quadrant(Offset offset) => VideoLayer(
        clips: [
          VideoSegment(
            video: EditorVideo.asset(testAPath),
            endTime: const Duration(seconds: 4),
            volume: 0,
          ),
        ],
        transform: SegmentTransform(offset: offset, size: cell),
      );

      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: m.resolution,
            layers: [
              quadrant(Offset.zero),
              quadrant(Offset(m.resolution.width / 2, 0)),
              quadrant(Offset(0, m.resolution.height / 2)),
              quadrant(Offset(m.resolution.width / 2, m.resolution.height / 2)),
            ],
          ),
        ),
      );

      expect(result, isNotNull);
      final out = await pve.getMetadata(EditorVideo.memory(result));
      expectResolution(out, m.resolution);
    });
  });

  group('Composition - Audio & opacity', () {
    testWidgets('semi-transparent overlay layer renders', (tester) async {
      final m = await meta(testAPath);

      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: m.resolution,
            layers: [
              VideoLayer(
                clips: [VideoSegment(video: EditorVideo.asset(testAPath))],
              ),
              VideoLayer(
                opacity: 0.5,
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testAPath),
                    endTime: const Duration(seconds: 4),
                    volume: 0,
                  ),
                ],
                transform: SegmentTransform(
                  offset: const Offset(40, 40),
                  size: Size(m.resolution.width / 2, m.resolution.height / 2),
                ),
              ),
            ],
          ),
        ),
      );

      expect(result, isNotNull);
      expect(result.lengthInBytes, greaterThan(50000));
    });

    testWidgets('audio disabled renders and keeps duration', (tester) async {
      final m = await meta(testAPath);

      final result = await pve.renderVideo(
        VideoRenderData(
          enableAudio: false,
          composition: VideoComposition(
            canvasSize: m.resolution,
            layers: [
              VideoLayer(
                clips: [VideoSegment(video: EditorVideo.asset(testAPath))],
              ),
            ],
          ),
        ),
      );

      final out = await pve.getMetadata(EditorVideo.memory(result));
      expect(
        out.duration.inSeconds,
        closeTo(m.duration.inSeconds, durationTolerance),
      );
    });

    testWidgets('silent source as overlay renders', (tester) async {
      final m = await meta(testAPath);

      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: m.resolution,
            layers: [
              VideoLayer(
                clips: [VideoSegment(video: EditorVideo.asset(testAPath))],
              ),
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testDPath), // no audio track
                    endTime: const Duration(seconds: 4),
                  ),
                ],
                transform: SegmentTransform(
                  offset: const Offset(20, 20),
                  size: Size(m.resolution.width / 3, m.resolution.height / 3),
                ),
              ),
            ],
          ),
        ),
      );

      expect(result, isNotNull);
    });
  });

  group('Composition - Visual', () {
    const visualCanvas = Size(640, 360);
    const red = Color(0xFFFF0000);

    testWidgets('background color fills the uncovered canvas area', (
      tester,
    ) async {
      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: visualCanvas,
            backgroundColor: red,
            layers: [
              VideoLayer(
                // Cover only the top-left; the rest stays background.
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testAPath),
                    endTime: const Duration(seconds: 2),
                  ),
                ],
                transform: const SegmentTransform(
                  offset: Offset.zero,
                  size: Size(256, 144),
                  fit: SegmentFit.fill,
                ),
              ),
            ],
          ),
        ),
      );

      final corner = await samplePixel(result, visualCanvas, 0.85, 0.85);
      expect(
        isRed(corner),
        isTrue,
        reason: 'Uncovered area should be the red background, got $corner',
      );
    });

    testWidgets('top layer is drawn over the bottom layer', (tester) async {
      // The two test clips look near-identical, so distinguish the layers by
      // sampling the SAME source at different times (its color changes over
      // time). The only variable left is which layer ends up on top.
      const at = Duration(milliseconds: 800);
      VideoRenderData single(Duration start) => VideoRenderData(
        composition: VideoComposition(
          canvasSize: visualCanvas,
          layers: [
            VideoLayer(
              clips: [
                VideoSegment(
                  video: EditorVideo.asset(testAPath),
                  startTime: start,
                  endTime: start + const Duration(seconds: 2),
                ),
              ],
            ),
          ],
        ),
      );

      final bottomOnly = await pve.renderVideo(single(Duration.zero));
      final topOnly = await pve.renderVideo(single(const Duration(seconds: 3)));
      final stacked = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: visualCanvas,
            layers: [
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testAPath),
                    startTime: Duration.zero,
                    endTime: const Duration(seconds: 2),
                  ),
                ],
              ),
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testAPath),
                    startTime: const Duration(seconds: 3),
                    endTime: const Duration(seconds: 5),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      final a = await samplePixel(bottomOnly, visualCanvas, 0.5, 0.5, at: at);
      final b = await samplePixel(topOnly, visualCanvas, 0.5, 0.5, at: at);
      final s = await samplePixel(stacked, visualCanvas, 0.5, 0.5, at: at);

      // Precondition: the source must look different at 0s vs 3s.
      expect(
        colorDist(a, b),
        greaterThan(20),
        reason:
            'Source not time-varying enough to assert z-order '
            '(bottom@0s=$a top@3s=$b)',
      );
      // The stacked center must match the TOP layer (source @3s), not bottom.
      expect(
        colorDist(s, b),
        lessThan(colorDist(s, a)),
        reason: 'Top layer should win: stacked=$s top=$b bottom=$a',
      );
    });

    testWidgets('cover overflow is clipped to the layer rect', (tester) async {
      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: visualCanvas,
            backgroundColor: red,
            layers: [
              VideoLayer(
                // Landscape rect + portrait source + cover => overflows.
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testBPath),
                    endTime: const Duration(seconds: 2),
                  ),
                ],
                transform: const SegmentTransform(
                  offset: Offset(160, 90),
                  size: Size(320, 180),
                  fit: SegmentFit.cover,
                ),
              ),
            ],
          ),
        ),
      );

      // Just above the rect (rect top y=90 => 0.25); 0.12 ~ y=43, background.
      final aboveRect = await samplePixel(result, visualCanvas, 0.5, 0.12);
      expect(
        isRed(aboveRect),
        isTrue,
        reason:
            'cover overflow must be clipped to its rect; the area above '
            'the rect should be background, got $aboveRect',
      );
    });

    testWidgets('segment rotation turns the placed box clockwise', (
      tester,
    ) async {
      // A deliberately WIDE box, so a 30 degree turn moves a lot of area and
      // the two sample points below can only be explained by a real rotation.
      // Centre (320, 180), half extents (100, 40) on the 640x360 canvas.
      //
      // A square box, or a multiple of 90 degrees, would be symmetric under
      // +/-theta and so could not tell a clockwise turn from a counter
      // clockwise one. These points can:
      //
      //   showsAfter  (250, 130): background upright, background if the turn
      //                           went counter clockwise, video only when it
      //                           went CLOCKWISE.
      //   hidesAfter  (400, 160): video upright, background once turned.
      Future<Uint8List> render({required double rotation}) => pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: visualCanvas,
            backgroundColor: red,
            layers: [
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testAPath),
                    endTime: const Duration(seconds: 2),
                  ),
                ],
                transform: SegmentTransform(
                  offset: const Offset(220, 140),
                  size: const Size(200, 80),
                  fit: SegmentFit.fill,
                  rotation: rotation,
                ),
              ),
            ],
          ),
        ),
      );

      Future<bool> redAt(Uint8List video, double x, double y) async =>
          isRed(await samplePixel(video, visualCanvas, x / 640, y / 360));

      final upright = await render(rotation: 0);
      final turned = await render(rotation: math.pi / 6);

      // Upright: the box is the horizontal strip y 140..220.
      expect(
        await redAt(upright, 250, 130),
        isTrue,
        reason: 'Upright, (250,130) sits above the box: must be background',
      );
      expect(
        await redAt(upright, 400, 160),
        isFalse,
        reason: 'Upright, (400,160) sits inside the box: must be video',
      );

      // Turned 30 degrees clockwise: the strip tilts so its left end lifts
      // and its right end drops, which swaps both points.
      expect(
        await redAt(turned, 250, 130),
        isFalse,
        reason:
            'A clockwise turn must bring (250,130) inside the box. Still '
            'background means the box did not turn, or turned the wrong way',
      );
      expect(
        await redAt(turned, 400, 160),
        isTrue,
        reason: 'A clockwise turn must push (400,160) out of the box',
      );

      // The turn is around the box centre, so the centre stays covered — and
      // this doubles as proof the render did not simply come out empty.
      expect(
        await redAt(turned, 320, 180),
        isFalse,
        reason: 'The box turns around its own centre, which stays video',
      );
    });

    testWidgets('a clip flagged with a rotation renders upright', (
      tester,
    ) async {
      // Regression: the Darwin layered compositor applied the flag in
      // CoreImage's y-up space, where a 90° turn goes the other way, so every
      // portrait phone recording came out upside down.
      const size = Size(360, 640);
      const at = Duration(seconds: 1);
      final video = EditorVideo.asset(testGPath);

      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: size,
            layers: [
              VideoLayer(clips: [VideoSegment(video: video)]),
            ],
          ),
        ),
      );

      final out = await frameOf(EditorVideo.memory(result), size, at: at);
      final source = await frameOf(video, size, at: at);
      expectUpright(out, source);
    });

    testWidgets('single clip trimmed before its source end keeps duration', (
      tester,
    ) async {
      // Regression: Media3 dropped the last GOP of a mid-source-end last clip.
      const trimmed = Duration(seconds: 3);
      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: visualCanvas,
            layers: [
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(testAPath),
                    startTime: Duration.zero,
                    endTime: trimmed, // 3s of a ~5s source
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      final out = await pve.getMetadata(EditorVideo.memory(result));
      expect(
        out.duration.inSeconds,
        closeTo(trimmed.inSeconds, durationTolerance),
        reason: 'A mid-source end-trim must keep its full trimmed length',
      );
    });
  });

  // On iOS/macOS the videoSegments path pre-transcodes HEVC 10-bit/HDR to
  // H.264 8-bit SDR before compositing; the composition path does not, and
  // hands the source to the compositor as it is. These tests hold it to the
  // colors and orientation the pre-transcode gives: the compositor receives
  // SDR frames from AVFoundation already, so the pre-transcode would only add
  // an encode pass here (#206).
  group('Composition - HDR source', () {
    final hevc = EditorVideo.asset(hevcPath);
    final skipPlatform =
        defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS;
    const at = Duration(seconds: 1);
    // The source's display aspect ratio, so `cover` crops nothing.
    const sourceSize = Size(180, 320);

    /// Rec.601 luminance of a pixel.
    double luma(List<int> c) => 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];

    testWidgets('two HDR layers render upright in their source colors', (
      tester,
    ) async {
      // Two 9:16 boxes side by side, each filled with the portrait source.
      VideoLayer layer(double left) => VideoLayer(
        clips: [
          VideoSegment(
            video: hevc,
            endTime: const Duration(seconds: 2),
            volume: 0,
          ),
        ],
        transform: SegmentTransform(
          offset: Offset(left, 0),
          size: const Size(360, 640),
          fit: SegmentFit.fill,
        ),
      );

      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: const Size(720, 640),
            layers: [layer(0), layer(360)],
          ),
        ),
      );

      final source = await tryFrameOf(hevc, sourceSize, at: at);
      if (source == null) {
        markTestSkipped('HDR HEVC frame not extractable on this device');
        return;
      }
      final out = await frameOf(
        EditorVideo.memory(result),
        const Size(360, 320),
        at: at,
      );

      for (final left in const [0.0, 0.5]) {
        expectUpright(out, source, left: left, width: 0.5);

        // Neither black nor off-color: close to the source thumbnail in
        // brightness and in every channel. Measured: luma 134 vs 125 and a
        // mean channel error of 10 (macOS), 137 vs 125 and 11.5 (iPad).
        var outLuma = 0.0, sourceLuma = 0.0, error = 0;
        for (final p in offAxisPoints) {
          final o = out.at(left + p.dx / 2, p.dy);
          final s = source.at(p.dx, p.dy);
          outLuma += luma(o) / offAxisPoints.length;
          sourceLuma += luma(s) / offAxisPoints.length;
          error += colorDist(o, s);
        }
        expect(
          outLuma,
          closeTo(sourceLuma, 25),
          reason: 'Layer at x=$left is too dark or too bright',
        );
        expect(
          error / (offAxisPoints.length * 3),
          lessThan(25),
          reason: 'Layer at x=$left is off its source colors',
        );
      }

      // The cast the videoSegments pre-transcode once had wrote green into
      // blue, B == G. Counted against R - G as in render_pixel_test, which
      // that bug leaves alone. Measured: 18062 vs 27292 (macOS), 18464 vs
      // 27777 (iPad); B == G gives 0.
      var blueApart = 0, redApart = 0;
      final total = out.width * out.height;
      for (var i = 0; i < total * 4; i += 4) {
        final r = out.data.getUint8(i);
        final g = out.data.getUint8(i + 1);
        final b = out.data.getUint8(i + 2);
        if ((b - g).abs() > 8) blueApart++;
        if ((r - g).abs() > 8) redApart++;
      }
      if (redApart < total ~/ 100) {
        markTestSkipped('HEVC render has no colored pixels on this device');
        return;
      }
      expect(
        blueApart,
        greaterThan(redApart ~/ 20),
        reason:
            'B == G across the frame ($blueApart pixels apart, $redApart '
            'differ in R): the blue channel was replaced',
      );
    }, skip: skipPlatform);

    testWidgets('a color filter applies to an HDR layer', (tester) async {
      final result = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: const Size(360, 640),
            layers: [
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: hevc,
                    endTime: const Duration(seconds: 2),
                  ),
                ],
              ),
            ],
          ),
          colorFilters: const [ColorFilter(matrix: _swapRedBlue)],
        ),
      );

      final source = await tryFrameOf(hevc, sourceSize, at: at);
      if (source == null) {
        markTestSkipped('HDR HEVC frame not extractable on this device');
        return;
      }
      final out = await frameOf(EditorVideo.memory(result), sourceSize, at: at);

      // Every pixel, since the sample points land on the gray face: only the
      // red hat and the gold trim have R and B far enough apart to tell.
      // Measured over ~6800 of them: swapped 110k vs kept 869k (macOS), 123k
      // vs 874k (iPad).
      expect(out.width * out.height, source.width * source.height);
      var tested = 0, swapError = 0, keepError = 0;
      for (var i = 0; i < source.width * source.height * 4; i += 4) {
        final srcR = source.data.getUint8(i);
        final srcB = source.data.getUint8(i + 2);
        if ((srcR - srcB).abs() < 30) continue; // R == B shows no swap
        tested++;
        final outR = out.data.getUint8(i);
        final outB = out.data.getUint8(i + 2);
        swapError += (outR - srcB).abs() + (outB - srcR).abs();
        keepError += (outR - srcR).abs() + (outB - srcB).abs();
      }
      expect(tested, greaterThan(0), reason: 'No R != B pixels in the source');
      expect(
        swapError,
        lessThan(keepError),
        reason: 'The filter did not swap red and blue on the HDR layer',
      );
    }, skip: skipPlatform);
  });
}

const _swapRedBlue = <double>[
  0, 0, 1, 0, 0, //
  0, 1, 0, 0, 0, //
  1, 0, 0, 0, 0, //
  0, 0, 0, 1, 0, //
];

/// A decoded RGBA frame.
class _Frame {
  _Frame(this.data, this.width, this.height);

  final ByteData data;
  final int width;
  final int height;

  /// RGBA at the relative position ([fx], [fy]) in `0..1`.
  List<int> at(double fx, double fy) {
    final px = (fx * (width - 1)).round().clamp(0, width - 1);
    final py = (fy * (height - 1)).round().clamp(0, height - 1);
    final i = (py * width + px) * 4;
    return [
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
      data.getUint8(i + 3),
    ];
  }
}
