import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Size, instantiateImageCodec;

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
  const testBPath = 'assets/tests/test_b.mp4'; // 720x1280 portrait, rotation
  const testDPath = 'assets/tests/test_d.mp4'; // 1920x1080, 30fps, no audio

  const durationTolerance = 0.3; // seconds
  const sizeTolerance = 4.0; // pixels (encoders round to even dimensions)

  Future<VideoMetadata> meta(String path) =>
      pve.getMetadata(EditorVideo.asset(path));

  void expectResolution(VideoMetadata out, Size expected) {
    expect(out.resolution.width, closeTo(expected.width, sizeTolerance));
    expect(out.resolution.height, closeTo(expected.height, sizeTolerance));
  }

  /// Decodes a frame of the rendered [video] at [at] and returns the RGBA of
  /// the pixel at the relative position ([fx], [fy]) in `0..1`.
  ///
  /// The frame is requested at the [canvas] size with `cover`; since the output
  /// resolution is the canvas size (matching aspect), there is no crop, so the
  /// relative position maps directly onto the composition canvas.
  Future<List<int>> samplePixel(
    Uint8List video,
    Size canvas,
    double fx,
    double fy, {
    Duration at = const Duration(milliseconds: 400),
  }) async {
    final frames = await pve.getThumbnails(
      ThumbnailConfigs(
        video: EditorVideo.memory(video),
        outputFormat: ThumbnailFormat.png,
        timestamps: [at],
        outputSize: canvas,
        boxFit: ThumbnailBoxFit.cover,
      ),
    );
    expect(frames, isNotEmpty, reason: 'No frame extracted from the output');
    final codec = await instantiateImageCodec(frames.first);
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData();
    final px = (fx * (image.width - 1)).round().clamp(0, image.width - 1);
    final py = (fy * (image.height - 1)).round().clamp(0, image.height - 1);
    final i = (py * image.width + px) * 4;
    return [
      data!.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
      data.getUint8(i + 3),
    ];
  }

  /// Sum of absolute per-channel (RGB) differences between two pixels.
  int colorDist(List<int> a, List<int> b) =>
      (a[0] - b[0]).abs() + (a[1] - b[1]).abs() + (a[2] - b[2]).abs();

  /// Whether a pixel is clearly the red background (tolerant of YUV rounding).
  bool isRed(List<int> c) => c[0] > 150 && c[1] < 90 && c[2] < 90;

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
}
