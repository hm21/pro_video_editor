import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// End-to-end verification that [LayerShapeMask] shapes a layer on every
/// frame: a `VideoLayer`'s clips and an [ImageLayer]'s image show inside the
/// shape and the picture beneath outside it, and keyframes move the shape
/// while the video plays.
///
/// As in `layer_mask_test`, every input is a solid color **synthesized
/// in-test**, so the assertions are about the mask alone, and they stay
/// tolerant of YUV/codec rounding.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  const baseRed = Color(0xFFE00000);
  const clipBlue = Color(0xFF1040D0);

  const canvas = Size(640, 360);

  /// A solid-color PNG of the canvas size.
  Future<Uint8List> solidPng(Color color) async {
    final recorder = PictureRecorder();
    Canvas(recorder).drawRect(Offset.zero & canvas, Paint()..color = color);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      canvas.width.toInt(),
      canvas.height.toInt(),
    );
    final data = await image.toByteData(format: ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// Turns a still image into a two-second video, as `layer_mask_test` does.
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

  /// The RGBA of the frame of [video] at [at], at the relative position
  /// ([fx], [fy]).
  Future<List<int>> samplePixel(
    Uint8List video,
    Duration at,
    double fx,
    double fy,
  ) async {
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

  bool isRed(List<int> c) => c[0] > 150 && c[1] < 100 && c[2] < 100;
  bool isBlue(List<int> c) => c[2] > 130 && c[0] < 120 && c[1] < 130;

  /// Expects [out] at [at] to show the masked blue at each of [shown] and the
  /// red beneath it at each of [hidden].
  Future<void> expectShape(
    Uint8List out,
    Duration at, {
    required List<Offset> shown,
    required List<Offset> hidden,
  }) async {
    for (final p in shown) {
      final c = await samplePixel(out, at, p.dx, p.dy);
      expect(isBlue(c), isTrue, reason: 'Hidden at $p, $at: got $c');
    }
    for (final p in hidden) {
      final c = await samplePixel(out, at, p.dx, p.dy);
      expect(isRed(c), isTrue, reason: 'Shown at $p, $at: got $c');
    }
  }

  /// A box over the left half at 0 that has moved over the right half by
  /// 2 s, along a straight line.
  const sliding = LayerShapeMask(
    shape: LayerShapeMaskShape.rectangle,
    keyframes: [
      LayerShapeMaskKeyframe(
        time: Duration.zero,
        center: Offset(0.25, 0.5),
        size: Size(0.5, 1.2),
      ),
      LayerShapeMaskKeyframe(
        time: Duration(seconds: 2),
        center: Offset(0.75, 0.5),
        size: Size(0.5, 1.2),
      ),
    ],
  );
  const early = Duration(milliseconds: 100);
  const late = Duration(milliseconds: 1900);
  const left = [Offset(0.1, 0.3), Offset(0.15, 0.7)];
  const right = [Offset(0.85, 0.3), Offset(0.9, 0.7)];

  late EditorVideo base;
  late EditorVideo clip;
  late Uint8List bluePng;

  setUpAll(() async {
    bluePng = await solidPng(clipBlue);
    base = await videoFromImage(await solidPng(baseRed));
    clip = await videoFromImage(bluePng);
  });

  group('VideoLayer.shapeMask', () {
    Future<Uint8List> renderMasked(LayerShapeMask mask) => pve.renderVideo(
      VideoRenderData(
        composition: VideoComposition(
          canvasSize: canvas,
          layers: [
            VideoLayer(clips: [VideoSegment(video: base)]),
            VideoLayer(
              clips: [VideoSegment(video: clip)],
              shapeMask: mask,
            ),
          ],
        ),
      ),
    );

    testWidgets('shows the clip inside a still shape only', (_) async {
      final out = await renderMasked(
        const LayerShapeMask(
          shape: LayerShapeMaskShape.ellipse,
          size: Size(0.6, 0.6),
        ),
      );

      await expectShape(
        out,
        const Duration(milliseconds: 400),
        shown: const [Offset(0.5, 0.5), Offset(0.4, 0.45)],
        hidden: const [Offset(0.05, 0.1), Offset(0.95, 0.9)],
      );
    });

    testWidgets('moves the shape with its keyframes', (_) async {
      final out = await renderMasked(sliding);

      await expectShape(out, early, shown: left, hidden: right);
      await expectShape(out, late, shown: right, hidden: left);
    });

    testWidgets('shows the clip outside an inverted shape', (_) async {
      final out = await renderMasked(sliding.copyWith(invert: true));

      await expectShape(out, early, shown: right, hidden: left);
    });
  });

  group('ImageLayer.shapeMask', () {
    Future<Uint8List> renderMasked(LayerShapeMask mask) => pve.renderVideo(
      VideoRenderData(
        videoSegments: [VideoSegment(video: base)],
        imageLayers: [
          ImageLayer(
            image: EditorLayerImage.memory(bluePng),
            offset: Offset.zero,
            size: canvas,
            shapeMask: mask,
          ),
        ],
      ),
    );

    testWidgets('moves the shape over the image with its keyframes', (_) async {
      final out = await renderMasked(sliding);

      await expectShape(out, early, shown: left, hidden: right);
      await expectShape(out, late, shown: right, hidden: left);
    });

    testWidgets('masks a turned layer in its own box', (_) async {
      // Turned half way round, the image's left half lands on the right.
      final out = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: base)],
          imageLayers: [
            ImageLayer(
              image: EditorLayerImage.memory(bluePng),
              offset: Offset.zero,
              size: canvas,
              rotation: math.pi,
              shapeMask: sliding
                  .copyWith(keyframes: const [])
                  .copyWith(
                    center: const Offset(0.25, 0.5),
                    size: const Size(0.5, 1.2),
                  ),
            ),
          ],
        ),
      );

      await expectShape(out, early, shown: right, hidden: left);
    });
  });
}
