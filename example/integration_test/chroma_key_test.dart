import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

/// End-to-end verification that the chroma key actually removes the screen and
/// fills it, on both the single-track and the layered path.
///
/// The green-screen source is **synthesized in-test** rather than shipped as a
/// binary asset: a painted PNG is turned into a video with `renderStopMotion`.
/// That keeps the input fully deterministic (exact colors, exact geometry), so
/// the assertions can be about the key rather than about some clip's content.
///
/// All assertions stay tolerant of YUV/codec rounding, consistent with the rest
/// of the suite.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  // SMPTE "chroma key green" — the ChromaKey default.
  const screenGreen = Color(0xFF00B140);
  // The subject: a saturated blue that is nowhere near the key hue.
  const subjectBlue = Color(0xFF1040D0);
  const backgroundRed = Color(0xFFE00000);

  const canvas = Size(640, 360);
  const frameAt = Duration(milliseconds: 400);

  /// Renders [paint] into a PNG of [size].
  Future<Uint8List> paintPng(Size size, void Function(Canvas) paint) async {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    paint(canvas);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    final data = await image.toByteData(format: ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// A PNG whose left half is [left] and right half is [right].
  Future<Uint8List> splitPng(Color left, Color right) {
    return paintPng(canvas, (c) {
      final w = canvas.width;
      final h = canvas.height;
      c
        ..drawRect(Rect.fromLTWH(0, 0, w / 2, h), Paint()..color = left)
        ..drawRect(Rect.fromLTWH(w / 2, 0, w / 2, h), Paint()..color = right);
    });
  }

  /// A solid-color PNG.
  Future<Uint8List> solidPng(Color color) {
    return paintPng(
      canvas,
      (c) => c.drawRect(
        Rect.fromLTWH(0, 0, canvas.width, canvas.height),
        Paint()..color = color,
      ),
    );
  }

  /// Turns a still image into a video the key can work on.
  ///
  /// Built by painting [png] over a real clip rather than by
  /// `renderStopMotion`: a stop-motion clip is a single held still, and two of
  /// those do not concatenate (verified: 2s + 2s comes out as 2.03s), which the
  /// multi-segment test below needs. Overlaying a real clip keeps a normal
  /// frame/GOP structure while making every pixel an exactly known color.
  Future<EditorVideo> videoFromImage(
    Uint8List png, {
    Duration duration = const Duration(seconds: 2),
  }) async {
    final bytes = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [
          VideoSegment(
            video: EditorVideo.asset('assets/tests/test_d.mp4'),
            endTime: duration,
          ),
        ],
        // No offset/size: the layer is stretched over the whole frame.
        imageLayers: [ImageLayer(image: EditorLayerImage.memory(png))],
        transform: ExportTransform(
          width: canvas.width.toInt(),
          height: canvas.height.toInt(),
        ),
      ),
    );
    return EditorVideo.memory(bytes);
  }

  /// Decodes a frame of [video] and returns the RGBA at the relative position
  /// ([fx], [fy]) in `0..1`.
  Future<List<int>> samplePixel(
    Uint8List video,
    double fx,
    double fy, {
    Duration at = frameAt,
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

  bool isRed(List<int> c) => c[0] > 150 && c[1] < 100 && c[2] < 100;
  bool isBlue(List<int> c) => c[2] > 130 && c[0] < 120 && c[1] < 130;
  bool isGreen(List<int> c) => c[1] > 110 && c[0] < 110;

  // Sample points well inside each half, away from the seam.
  const leftPoints = <Offset>[
    Offset(0.15, 0.3),
    Offset(0.25, 0.5),
    Offset(0.15, 0.7),
  ];
  const rightPoints = <Offset>[
    Offset(0.75, 0.3),
    Offset(0.85, 0.5),
    Offset(0.75, 0.7),
  ];

  /// The green/blue split source, built once and shared by the tests.
  late EditorVideo greenScreen;

  setUpAll(() async {
    greenScreen = await videoFromImage(
      await splitPng(screenGreen, subjectBlue),
    );

    // Guard the fixture itself: if the synthesized source is not actually
    // green on the left and blue on the right, every assertion below would be
    // meaningless.
    final source = await greenScreen.safeByteArray();
    for (final p in leftPoints) {
      expect(
        isGreen(await samplePixel(source, p.dx, p.dy)),
        isTrue,
        reason: 'Fixture is not green at $p',
      );
    }
    for (final p in rightPoints) {
      expect(
        isBlue(await samplePixel(source, p.dx, p.dy)),
        isTrue,
        reason: 'Fixture is not blue at $p',
      );
    }
  });

  group('ChromaKey - single track', () {
    testWidgets('a color background replaces the screen', (_) async {
      final out = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: greenScreen)],
          chromaKey: const ChromaKey(backgroundColor: backgroundRed),
        ),
      );

      for (final p in leftPoints) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isRed(c), isTrue, reason: 'Screen not replaced at $p, got $c');
      }
    });

    testWidgets('the subject is left alone', (_) async {
      final out = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: greenScreen)],
          chromaKey: const ChromaKey(backgroundColor: backgroundRed),
        ),
      );

      for (final p in rightPoints) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isBlue(c), isTrue, reason: 'Subject was keyed at $p, got $c');
      }
    });

    testWidgets('a tiny similarity keys nothing', (_) async {
      // The regression guard: with the threshold below the encoder's own
      // rounding of the key color, the output must still be the source.
      final out = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: greenScreen)],
          chromaKey: const ChromaKey(
            similarity: 0.001,
            smoothness: 0,
            spill: 0,
            backgroundColor: backgroundRed,
          ),
        ),
      );

      for (final p in leftPoints) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isRed(c), isFalse, reason: 'Keyed despite similarity≈0 at $p');
        expect(isGreen(c), isTrue, reason: 'Screen not preserved at $p');
      }
    });

    testWidgets('an image background fills the screen', (_) async {
      final out = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: greenScreen)],
          chromaKey: ChromaKey(
            backgroundImage: EditorLayerImage.memory(
              await solidPng(backgroundRed),
            ),
          ),
        ),
      );

      for (final p in leftPoints) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isRed(c), isTrue, reason: 'Background image missing at $p');
      }
      for (final p in rightPoints) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isBlue(c), isTrue, reason: 'Subject was keyed at $p, got $c');
      }
    });

    testWidgets('a color filter does not un-key the frame', (_) async {
      // Apple folds the key and the filter into one CIColorCube because a
      // second cube would take its alpha from its own data and resurrect the
      // screen. This is the regression guard for that.
      final out = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: greenScreen)],
          chromaKey: const ChromaKey(backgroundColor: backgroundRed),
          colorFilters: const [
            ColorFilter(
              matrix: [
                0.299, 0.587, 0.114, 0, 0, //
                0.299, 0.587, 0.114, 0, 0, //
                0.299, 0.587, 0.114, 0, 0, //
                0, 0, 0, 1, 0, //
              ],
            ),
          ],
        ),
      );

      for (final p in leftPoints) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(
          isGreen(c),
          isFalse,
          reason: 'The color filter resurrected the screen at $p, got $c',
        );
        // Grayscaled red: R==G==B, and clearly not the original green.
        expect(
          (c[0] - c[1]).abs() < 30 && (c[1] - c[2]).abs() < 30,
          isTrue,
          reason: 'Output is not grayscale at $p, got $c',
        );
      }
    });

    testWidgets('a bitrate cap does not skip the key via passthrough', (
      _,
    ) async {
      // A single untrimmed clip within the cap would otherwise take the
      // lossless fast path (Apple passthrough / Android transmux) and the key
      // would silently do nothing.
      final out = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: greenScreen)],
          chromaKey: const ChromaKey(backgroundColor: backgroundRed),
          bitrate: 8000000,
        ),
      );

      for (final p in leftPoints) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isRed(c), isTrue, reason: 'Passthrough skipped the key at $p');
      }
    });

    testWidgets('imageBytesWithCropping keys in both branches', (_) async {
      // The compositor duplicates its effect chain across this flag, so both
      // sides have to be exercised or one can silently lose the key.
      for (final withCropping in [false, true]) {
        final out = await pve.renderVideo(
          VideoRenderData(
            videoSegments: [VideoSegment(video: greenScreen)],
            chromaKey: const ChromaKey(backgroundColor: backgroundRed),
            imageBytesWithCropping: withCropping,
          ),
        );

        for (final p in leftPoints) {
          final c = await samplePixel(out, p.dx, p.dy);
          expect(
            isRed(c),
            isTrue,
            reason: 'Key lost with imageBytesWithCropping=$withCropping at $p',
          );
        }
      }
    });

    testWidgets('a per-segment key overrides the global one', (_) async {
      // Two sources, each re-encoded once through the normal render path: a
      // stop-motion clip holds a single still for its whole duration, and two
      // of those concatenate down to one segment. Re-encoding gives them an
      // ordinary frame/GOP structure.
      const half = Duration(seconds: 2);
      Future<EditorVideo> concatenatable(Color right) async {
        final still = await videoFromImage(
          await splitPng(screenGreen, right),
          duration: half,
        );
        return EditorVideo.memory(
          await pve.renderVideo(
            VideoRenderData(videoSegments: [VideoSegment(video: still)]),
          ),
        );
      }

      final firstSource = await concatenatable(subjectBlue);
      final secondSource = await concatenatable(const Color(0xFF804000));

      final out = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(video: firstSource),
            VideoSegment(
              video: secondSource,
              // Overrides the global red with a distinctly different fill.
              chromaKey: const ChromaKey(
                backgroundColor: Color(0xFFFFFFFF),
              ),
            ),
          ],
          chromaKey: const ChromaKey(backgroundColor: backgroundRed),
        ),
      );

      // Sample a quarter and three quarters into the real output rather than at
      // fixed timestamps: the concatenated length depends on how the encoder
      // rounds each segment, and a timestamp past the end yields no frame.
      final duration = (await pve.getMetadata(
        EditorVideo.memory(out),
      )).duration;
      expect(
        duration.inMilliseconds,
        closeTo(4000, 700),
        reason: 'Both segments should be in the output, got $duration',
      );
      final inFirst = duration * 0.25;
      final inSecond = duration * 0.75;

      // First segment: the global key's red.
      final first = await samplePixel(out, 0.2, 0.5, at: inFirst);
      expect(
        isRed(first),
        isTrue,
        reason: 'Global key not applied, got $first',
      );

      // Second segment: its own key's white.
      final second = await samplePixel(out, 0.2, 0.5, at: inSecond);
      expect(
        second[0] > 180 && second[1] > 180 && second[2] > 180,
        isTrue,
        reason: 'Per-segment key did not override the global one, got $second',
      );
    });
  });

  group('ChromaKey - autoDetect', () {
    testWidgets('measures the real studio screen', (_) async {
      final detection = await ChromaKey.detect(
        EditorVideo.asset('assets/greenscreen.mp4'),
      );

      // The recorded screen, not the paint it was mixed from: SMPTE green is
      // 0xFF00B140, the camera saw roughly 0xFF2A9D37.
      expect(detection.coverage, greaterThan(0.9));
      expect(
        detection.color.g,
        greaterThan(detection.color.r),
        reason: 'a green screen should detect as green, got ${detection.color}',
      );
      expect(
        detection.color.g,
        greaterThan(detection.color.b),
        reason: 'a green screen should detect as green, got ${detection.color}',
      );

      // The whole point: a measured key sits much closer to the screen than
      // the SMPTE constant, so it needs far less similarity to cover it.
      expect(
        detection.similarity,
        lessThan(const ChromaKey().similarity),
        reason: 'measured ${detection.similarity} should beat the constant',
      );
    });

    testWidgets('the detected key removes the screen', (_) async {
      final gs = EditorVideo.asset('assets/greenscreen.mp4');
      final key = await ChromaKey.autoDetect(
        gs,
        backgroundColor: backgroundRed,
      );

      final out = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: gs)],
          chromaKey: key,
        ),
      );

      // Corners: screen everywhere, including the dimly lit bottom ones that
      // survive a too-tight constant key.
      for (final p in const [
        Offset(0.05, 0.05),
        Offset(0.95, 0.05),
        Offset(0.05, 0.95),
        Offset(0.95, 0.95),
        Offset(0.15, 0.5),
      ]) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isRed(c), isTrue, reason: 'Screen survived at $p, got $c');
      }
    });

    testWidgets('the detected key keeps the subject', (_) async {
      final gs = EditorVideo.asset('assets/greenscreen.mp4');
      final key = await ChromaKey.autoDetect(
        gs,
        backgroundColor: backgroundRed,
      );

      final out = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: gs)],
          chromaKey: key,
        ),
      );

      // Center of the subject: pink outfit, must not be keyed.
      final c = await samplePixel(out, 0.66, 0.45);
      expect(
        isRed(c),
        isFalse,
        reason: 'The subject was keyed away, got $c',
      );
    });

    testWidgets('rejects a frame that is not a screen', (_) async {
      // The plain demo video has no screen at all.
      expect(
        () => ChromaKey.detect(
          EditorVideo.asset(kVideoEditorExampleH264Path),
        ),
        throwsA(isA<ChromaKeyDetectionException>()),
      );
    });
  });

  group('ChromaKey - composition', () {
    testWidgets('a transparent key lets the layer below show through', (
      _,
    ) async {
      // The one case that exercises real transparency end to end: it would
      // fail on a premultiplied/straight alpha mix-up, on a Media3 blend
      // regression, and on the VideoCompositionTransformation alpha-squaring.
      final backdrop = await videoFromImage(await solidPng(backgroundRed));

      final out = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: canvas,
            layers: [
              VideoLayer(clips: [VideoSegment(video: backdrop)]),
              VideoLayer(
                clips: [VideoSegment(video: greenScreen)],
                chromaKey: const ChromaKey(),
              ),
            ],
          ),
        ),
      );

      for (final p in leftPoints) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(
          isRed(c),
          isTrue,
          reason: 'The layer below does not show through at $p, got $c',
        );
        // Specifically not black: that is what a flattened alpha looks like.
        expect(
          colorDist(c, [0, 0, 0, 255]) > 90,
          isTrue,
          reason: 'Keyed area came out black at $p, got $c',
        );
      }

      for (final p in rightPoints) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isBlue(c), isTrue, reason: 'Subject was keyed at $p, got $c');
      }
    });

    testWidgets('a per-clip key overrides the layer key', (_) async {
      final backdrop = await videoFromImage(await solidPng(backgroundRed));

      final out = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: canvas,
            layers: [
              VideoLayer(clips: [VideoSegment(video: backdrop)]),
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: greenScreen,
                    // Keys almost nothing, overriding the layer's default key.
                    chromaKey: const ChromaKey(
                      similarity: 0.001,
                      smoothness: 0,
                      spill: 0,
                    ),
                  ),
                ],
                chromaKey: const ChromaKey(),
              ),
            ],
          ),
        ),
      );

      for (final p in leftPoints) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(
          isGreen(c),
          isTrue,
          reason: 'The layer key won over the clip key at $p, got $c',
        );
      }
    });
  });
}
