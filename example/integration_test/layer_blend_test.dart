import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// End-to-end verification that [VideoLayer.blendMode] and
/// [ImageLayer.blendMode] combine a layer with the picture beneath it, as
/// Flutter paints the same [LayerBlendMode.blendMode] on screen.
///
/// Every input is a solid gray **synthesized in-test**, as in
/// `layer_mask_test`, and the expected gray is the W3C blend formula applied
/// to the grays the inputs were painted with: the renderers blend the values
/// as they are stored, with no color management. A frame read back through
/// `getThumbnails` is color managed, though (a stored 48 reads as about 54 on
/// macOS), so every output is compared with a reference video of the expected
/// gray, read back the same way.
///
/// Grays, because a gray survives the trip through YUV whatever matrix a
/// decoder converts it with: a saturated color comes out of the render's own
/// decode and of the thumbnail's up to ~20 apart per channel. The channels are
/// blended apart with the same formula each, which the native unit tests pin
/// with colors.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  // Overlay and soft light switch formulas at a backdrop of 1/2 (soft light
  // also at 1/4) and a layer of 1/2: the dark backdrop with the light layer
  // and the light backdrop with the dark layer take every branch.
  const darkBackdrop = Color(0xFF303030);
  const lightBackdrop = Color(0xFFB0B0B0);
  const lightLayer = Color(0xFFD0D0D0);
  const darkLayer = Color(0xFF606060);
  const cover = Color(0xFFF0F0F0);

  const canvas = Size(640, 360);
  const defaultTime = Duration(milliseconds: 400);
  const tolerance = 4;

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

  /// A solid-color PNG of [size].
  Future<Uint8List> solidPng(Color color, [Size size = canvas]) => paintPng(
    size,
    (c) => c.drawRect(Offset.zero & size, Paint()..color = color),
  );

  /// Turns a still image into a 2 s video of the canvas size.
  Future<EditorVideo> videoFromImage(Uint8List png) async {
    final bytes = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [
          VideoSegment(
            video: EditorVideo.asset('assets/tests/test_d.mp4'),
            endTime: const Duration(seconds: 2),
          ),
        ],
        imageLayers: [ImageLayer(image: EditorLayerImage.memory(png))],
        transform: ExportTransform(
          width: canvas.width.toInt(),
          height: canvas.height.toInt(),
        ),
      ),
    );
    return EditorVideo.memory(bytes);
  }

  /// The RGB of the frame of [video] at [time], at the relative position
  /// ([fx], [fy]).
  Future<List<int>> samplePixel(
    Uint8List video,
    double fx,
    double fy, {
    Duration time = defaultTime,
  }) async {
    final frames = await pve.getThumbnails(
      ThumbnailConfigs(
        video: EditorVideo.memory(video),
        outputFormat: ThumbnailFormat.png,
        timestamps: [time],
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
    return [data!.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2)];
  }

  /// The W3C separable blend of one channel, both from 0 to 1.
  double blendChannel(LayerBlendMode mode, double cb, double cs) {
    switch (mode) {
      case LayerBlendMode.normal:
      case LayerBlendMode.add:
        return cs;
      case LayerBlendMode.multiply:
        return cb * cs;
      case LayerBlendMode.screen:
        return cb + cs - cb * cs;
      case LayerBlendMode.overlay:
        return cb <= 0.5 ? 2 * cb * cs : 1 - 2 * (1 - cb) * (1 - cs);
      case LayerBlendMode.softLight:
        final d = cb <= 0.25 ? ((16 * cb - 12) * cb + 4) * cb : math.sqrt(cb);
        return cs <= 0.5
            ? cb - (1 - 2 * cs) * cb * (1 - cb)
            : cb + (2 * cs - 1) * (d - cb);
      case LayerBlendMode.darken:
        return math.min(cb, cs);
      case LayerBlendMode.lighten:
        return math.max(cb, cs);
      case LayerBlendMode.difference:
        return (cb - cs).abs();
    }
  }

  /// The gray [layer] at [alpha] blends to onto the opaque gray [backdrop]
  /// in [mode], both as bytes.
  int blended(
    LayerBlendMode mode,
    int backdrop,
    int layer, {
    double alpha = 1,
  }) {
    final cb = backdrop / 255;
    final cs = layer / 255;
    final value = mode == LayerBlendMode.add
        ? math.min(1.0, cb + alpha * cs)
        : (1 - alpha) * cb + alpha * blendChannel(mode, cb, cs);
    return (255 * value).round();
  }

  /// The gray [value], rendered to a video and read back as an output is.
  final references = <int, List<int>>{};
  Future<List<int>> reference(int value) async {
    if (references[value] case final rgb?) return rgb;
    final video = await videoFromImage(
      await solidPng(Color.fromARGB(255, value, value, value)),
    );
    return references[value] = await samplePixel(
      await video.safeByteArray(),
      0.5,
      0.5,
    );
  }

  /// Expects [actual] to read back as the gray [value] does.
  Future<void> expectGray(List<int> actual, int value, String what) async {
    final expected = await reference(value);
    for (var i = 0; i < 3; i++) {
      expect(
        (actual[i] - expected[i]).abs(),
        lessThanOrEqualTo(tolerance),
        reason: '$what: got $actual, expected $expected (gray $value)',
      );
    }
  }

  /// The byte the gray [color] is painted with.
  int grayOf(Color color) => (color.r * 255).round();

  /// A video of the gray [color], with that gray.
  Future<(EditorVideo, int)> fixture(Color color) async =>
      (await videoFromImage(await solidPng(color)), grayOf(color));

  late (EditorVideo, int) darkBackdropVideo;
  late (EditorVideo, int) lightBackdropVideo;
  late (EditorVideo, int) lightLayerVideo;
  late (EditorVideo, int) darkLayerVideo;
  late (EditorVideo, int) coverVideo;

  setUpAll(() async {
    darkBackdropVideo = await fixture(darkBackdrop);
    lightBackdropVideo = await fixture(lightBackdrop);
    lightLayerVideo = await fixture(lightLayer);
    darkLayerVideo = await fixture(darkLayer);
    coverVideo = await fixture(cover);
  });

  group('VideoLayer.blendMode', () {
    testWidgets('blends the layer onto the layer below in every mode', (
      _,
    ) async {
      for (final (backdrop, layer) in [
        (darkBackdropVideo, lightLayerVideo),
        (lightBackdropVideo, darkLayerVideo),
      ]) {
        for (final mode in LayerBlendMode.values) {
          final out = await pve.renderVideo(
            VideoRenderData(
              composition: VideoComposition(
                canvasSize: canvas,
                layers: [
                  VideoLayer(clips: [VideoSegment(video: backdrop.$1)]),
                  VideoLayer(
                    clips: [VideoSegment(video: layer.$1)],
                    blendMode: mode,
                  ),
                ],
              ),
            ),
          );

          await expectGray(
            await samplePixel(out, 0.5, 0.5),
            blended(mode, backdrop.$2, layer.$2),
            '$mode of ${layer.$2} onto ${backdrop.$2}',
          );
        }
      }
    });

    testWidgets('fades with the opacity and leaves the backdrop beside the '
        'clip as it is', (_) async {
      final (backdrop, backdropGray) = darkBackdropVideo;
      final (layer, layerGray) = lightLayerVideo;
      final out = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: canvas,
            layers: [
              VideoLayer(clips: [VideoSegment(video: backdrop)]),
              VideoLayer(
                clips: [VideoSegment(video: layer)],
                opacity: 0.5,
                transform: const SegmentTransform(
                  offset: Offset.zero,
                  size: Size(320, 360),
                  fit: SegmentFit.fill,
                ),
                blendMode: LayerBlendMode.screen,
              ),
            ],
          ),
        ),
      );

      await expectGray(
        await samplePixel(out, 0.25, 0.5),
        blended(LayerBlendMode.screen, backdropGray, layerGray, alpha: 0.5),
        'half-opaque screen',
      );
      await expectGray(
        await samplePixel(out, 0.75, 0.5),
        backdropGray,
        'beside',
      );
    });

    testWidgets('a normal layer above a blended one still covers it', (
      _,
    ) async {
      final (backdrop, backdropGray) = lightBackdropVideo;
      final (layer, layerGray) = darkLayerVideo;
      final out = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: canvas,
            layers: [
              VideoLayer(clips: [VideoSegment(video: backdrop)]),
              VideoLayer(
                clips: [VideoSegment(video: layer)],
                blendMode: LayerBlendMode.multiply,
              ),
              VideoLayer(
                clips: [VideoSegment(video: coverVideo.$1)],
                transform: const SegmentTransform(
                  offset: Offset.zero,
                  size: Size(160, 90),
                  fit: SegmentFit.fill,
                ),
              ),
            ],
          ),
        ),
      );

      await expectGray(
        await samplePixel(out, 0.1, 0.1),
        coverVideo.$2,
        'cover',
      );
      await expectGray(
        await samplePixel(out, 0.5, 0.5),
        blended(LayerBlendMode.multiply, backdropGray, layerGray),
        'multiply beside the cover',
      );
    });

    testWidgets('more layers than one pass draws keep their order', (_) async {
      // Android draws at most seven captured layers a pass: the blended
      // layer and the seven above it take two, and the top one blends with
      // what the first drew.
      final (backdrop, backdropGray) = lightBackdropVideo;
      final (layer, layerGray) = darkLayerVideo;
      final (top, topGray) = lightLayerVideo;
      final (cover, coverGray) = coverVideo;
      final out = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: canvas,
            layers: [
              VideoLayer(clips: [VideoSegment(video: backdrop)]),
              VideoLayer(
                clips: [VideoSegment(video: layer)],
                blendMode: LayerBlendMode.multiply,
              ),
              // Six boxes of 80 by 90 along the top edge.
              for (var column = 0; column < 6; column++)
                VideoLayer(
                  clips: [VideoSegment(video: cover)],
                  transform: SegmentTransform(
                    offset: Offset(column * 80.0, 0),
                    size: const Size(80, 90),
                    fit: SegmentFit.fill,
                  ),
                ),
              // Over the left half.
              VideoLayer(
                clips: [VideoSegment(video: top)],
                transform: const SegmentTransform(
                  offset: Offset.zero,
                  size: Size(320, 360),
                  fit: SegmentFit.fill,
                ),
                blendMode: LayerBlendMode.difference,
              ),
            ],
          ),
        ),
      );

      final multiplied = blended(
        LayerBlendMode.multiply,
        backdropGray,
        layerGray,
      );
      await expectGray(
        await samplePixel(out, 40 / 640, 45 / 360),
        blended(LayerBlendMode.difference, coverGray, topGray),
        'difference over a box',
      );
      await expectGray(
        await samplePixel(out, 440 / 640, 45 / 360),
        coverGray,
        'a box',
      );
      await expectGray(
        await samplePixel(out, 0.25, 0.75),
        blended(LayerBlendMode.difference, multiplied, topGray),
        'difference over the multiply',
      );
      await expectGray(
        await samplePixel(out, 0.875, 0.75),
        multiplied,
        'multiply',
      );
    });

    testWidgets('blends only while its clip plays', (_) async {
      final (backdrop, backdropGray) = lightBackdropVideo;
      final (layer, layerGray) = darkLayerVideo;
      final out = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: canvas,
            layers: [
              VideoLayer(clips: [VideoSegment(video: backdrop)]),
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: layer,
                    endTime: const Duration(milliseconds: 600),
                    timelineStart: const Duration(milliseconds: 600),
                  ),
                ],
                blendMode: LayerBlendMode.difference,
              ),
            ],
          ),
        ),
      );

      Future<List<int>> at(int ms) =>
          samplePixel(out, 0.5, 0.5, time: Duration(milliseconds: ms));
      await expectGray(await at(300), backdropGray, 'before the clip');
      await expectGray(
        await at(900),
        blended(LayerBlendMode.difference, backdropGray, layerGray),
        'while the clip plays',
      );
      await expectGray(await at(1600), backdropGray, 'after the clip');
    });
  });

  group('ImageLayer.blendMode', () {
    testWidgets('blends the image onto the video beneath it in every mode', (
      _,
    ) async {
      for (final (backdrop, layer) in [
        (darkBackdropVideo, lightLayer),
        (lightBackdropVideo, darkLayer),
      ]) {
        final image = EditorLayerImage.memory(await solidPng(layer));
        for (final mode in LayerBlendMode.values) {
          final out = await pve.renderVideo(
            VideoRenderData(
              videoSegments: [VideoSegment(video: backdrop.$1)],
              imageLayers: [ImageLayer(image: image, blendMode: mode)],
            ),
          );

          await expectGray(
            await samplePixel(out, 0.5, 0.5),
            blended(mode, backdrop.$2, grayOf(layer)),
            '$mode of $layer onto ${backdrop.$2}',
          );
        }
      }
    });

    testWidgets('fades with a keyframe and leaves the picture beside it', (
      _,
    ) async {
      final (backdrop, backdropGray) = lightBackdropVideo;
      final out = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: backdrop)],
          imageLayers: [
            ImageLayer(
              image: EditorLayerImage.memory(
                await solidPng(darkLayer, const Size(320, 360)),
              ),
              offset: Offset.zero,
              size: const Size(320, 360),
              keyframes: const [
                TimelineKeyframe(
                  time: Duration.zero,
                  offset: Offset.zero,
                  opacity: 0.5,
                ),
              ],
              blendMode: LayerBlendMode.multiply,
            ),
          ],
        ),
      );

      await expectGray(
        await samplePixel(out, 0.25, 0.5),
        blended(
          LayerBlendMode.multiply,
          backdropGray,
          grayOf(darkLayer),
          alpha: 0.5,
        ),
        'half-opaque multiply',
      );
      await expectGray(
        await samplePixel(out, 0.75, 0.5),
        backdropGray,
        'beside',
      );
    });

    testWidgets('blends onto blended video layers, in order', (_) async {
      // The image layers lie over every video layer, so the multiply works
      // on the screened composition rather than on the backdrop alone.
      final (backdrop, backdropGray) = darkBackdropVideo;
      final (layer, layerGray) = darkLayerVideo;
      final out = await pve.renderVideo(
        VideoRenderData(
          composition: VideoComposition(
            canvasSize: canvas,
            layers: [
              VideoLayer(clips: [VideoSegment(video: backdrop)]),
              VideoLayer(
                clips: [VideoSegment(video: layer)],
                blendMode: LayerBlendMode.screen,
              ),
            ],
          ),
          imageLayers: [
            ImageLayer(
              image: EditorLayerImage.memory(await solidPng(lightLayer)),
              blendMode: LayerBlendMode.multiply,
            ),
          ],
        ),
      );

      final screened = blended(LayerBlendMode.screen, backdropGray, layerGray);
      await expectGray(
        await samplePixel(out, 0.5, 0.5),
        blended(LayerBlendMode.multiply, screened, grayOf(lightLayer)),
        'screen, then multiply',
      );
    });
  });
}
