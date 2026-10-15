import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// End-to-end verification that [VideoLayer.mask] shapes a layer's clips:
/// the clip shows where the matte is opaque, the layer below where it is
/// transparent, a blend of the two where it is partly transparent, and the
/// matte moves with the clip's placement.
///
/// Both layers are solid colors **synthesized in-test**, as in
/// `chroma_key_test`: a painted PNG laid over a real clip, so every pixel of
/// the input is known and the assertions are about the mask alone. They stay
/// tolerant of YUV/codec rounding, consistent with the rest of the suite.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  const baseRed = Color(0xFFE00000);
  const clipBlue = Color(0xFF1040D0);

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

  /// A PNG of the canvas size, clear except for [rect] in [color].
  Future<Uint8List> pngWith(Rect rect, Color color) {
    return paintPng(canvas, (c) => c.drawRect(rect, Paint()..color = color));
  }

  /// A solid-color PNG of the canvas size.
  Future<Uint8List> solidPng(Color color) =>
      pngWith(Offset.zero & canvas, color);

  /// Turns a still image into a video, as `chroma_key_test` does.
  Future<EditorVideo> videoFromImage(Uint8List png) async {
    final bytes = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [
          VideoSegment(
            video: EditorVideo.asset('assets/tests/test_d.mp4'),
            endTime: const Duration(seconds: 2),
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

  /// The RGBA of a frame of [video] at the relative position ([fx], [fy]).
  Future<List<int>> samplePixel(Uint8List video, double fx, double fy) async {
    final frames = await pve.getThumbnails(
      ThumbnailConfigs(
        video: EditorVideo.memory(video),
        outputFormat: ThumbnailFormat.png,
        timestamps: [frameAt],
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

  /// The red base layer and the blue clip, built once and shared.
  late EditorVideo base;
  late EditorVideo clip;

  /// Renders the blue clip, shaped by [mask], over the red base layer.
  Future<Uint8List> renderMasked(
    Uint8List mask, {
    SegmentTransform? transform,
  }) {
    return pve.renderVideo(
      VideoRenderData(
        composition: VideoComposition(
          canvasSize: canvas,
          layers: [
            VideoLayer(clips: [VideoSegment(video: base)]),
            VideoLayer(
              clips: [VideoSegment(video: clip)],
              transform: transform,
              mask: EditorLayerImage.memory(mask),
            ),
          ],
        ),
      ),
    );
  }

  setUpAll(() async {
    base = await videoFromImage(await solidPng(baseRed));
    clip = await videoFromImage(await solidPng(clipBlue));

    // Guard the fixtures: every assertion below reads these two colors.
    expect(
      isRed(await samplePixel(await base.safeByteArray(), 0.5, 0.5)),
      isTrue,
    );
    expect(
      isBlue(await samplePixel(await clip.safeByteArray(), 0.5, 0.5)),
      isTrue,
    );
  });

  group('VideoLayer.mask', () {
    testWidgets('shows the clip where the matte is opaque and the layer below '
        'where it is transparent', (_) async {
      final out = await renderMasked(
        await pngWith(const Rect.fromLTWH(0, 0, 320, 360), clipBlue),
      );

      for (final p in const [Offset(0.15, 0.3), Offset(0.3, 0.7)]) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isBlue(c), isTrue, reason: 'The clip is hidden at $p, got $c');
      }
      for (final p in const [Offset(0.7, 0.3), Offset(0.85, 0.7)]) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(
          isRed(c),
          isTrue,
          reason: 'The layer below does not show through at $p, got $c',
        );
      }
    });

    testWidgets('stretches a larger matte of another aspect ratio over the '
        'clip', (_) async {
      // Three times the clip's width and four times its height, so it is
      // brought down on each axis on its own before the stretch. It still
      // splits the clip in half.
      final mask = await paintPng(
        const Size(1920, 1440),
        (c) => c.drawRect(
          const Rect.fromLTWH(0, 0, 960, 1440),
          Paint()..color = clipBlue,
        ),
      );
      final out = await renderMasked(mask);

      for (final p in const [Offset(0.15, 0.3), Offset(0.3, 0.7)]) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isBlue(c), isTrue, reason: 'The clip is hidden at $p, got $c');
      }
      for (final p in const [Offset(0.7, 0.3), Offset(0.85, 0.7)]) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isRed(c), isTrue, reason: 'Expected the base at $p, got $c');
      }
    });

    testWidgets('blends with the layer below where the matte is partly '
        'transparent', (_) async {
      // Half alpha on the right: a clip whose alpha were scaled twice — once
      // as alpha, once more through premultiplied color — would come out
      // with only a quarter of its blue.
      final mask = await paintPng(canvas, (c) {
        c
          ..drawRect(
            const Rect.fromLTWH(0, 0, 320, 360),
            Paint()..color = const Color(0xFFFFFFFF),
          )
          ..drawRect(
            const Rect.fromLTWH(320, 0, 320, 360),
            Paint()..color = const Color(0x80FFFFFF),
          );
      });
      final out = await renderMasked(mask);

      final left = await samplePixel(out, 0.2, 0.5);
      expect(isBlue(left), isTrue, reason: 'Opaque half lost the clip: $left');

      // Half of 0xE00000 and half of 0x1040D0 is about (120, 32, 104).
      final mixed = await samplePixel(out, 0.8, 0.5);
      expect(mixed[0], inInclusiveRange(80, 160), reason: 'Mix: $mixed');
      expect(mixed[2], inInclusiveRange(70, 140), reason: 'Mix: $mixed');
    });

    testWidgets('moves with the clip, upright, rather than staying on the '
        'canvas', (_) async {
      // Opaque only in the top-left quarter of the clip's own frame. Placed
      // in the right half of the canvas, that quarter lands at the top of
      // x 320–480. Stretched over the canvas instead, it would miss the clip
      // entirely; turned upside down, it would land at the bottom.
      final out = await renderMasked(
        await pngWith(const Rect.fromLTWH(0, 0, 320, 180), clipBlue),
        transform: const SegmentTransform(
          offset: Offset(320, 0),
          size: Size(320, 360),
          fit: SegmentFit.fill,
        ),
      );

      final shown = await samplePixel(out, 0.62, 0.25);
      expect(isBlue(shown), isTrue, reason: 'Masked-in quarter: $shown');

      for (final p in const [
        Offset(0.62, 0.75), // below it, in the clip
        Offset(0.88, 0.25), // beside it, in the clip
        Offset(0.88, 0.75),
        Offset(0.2, 0.25), // outside the clip
      ]) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isRed(c), isTrue, reason: 'Expected the base at $p, got $c');
      }
    });

    testWidgets('turns with the clip', (_) async {
      // The same top-left quarter, on a clip turned half way round its box:
      // the quarter comes out at the bottom right of x 320–640. A mask
      // applied after the turn would stay at the top left.
      final out = await renderMasked(
        await pngWith(const Rect.fromLTWH(0, 0, 320, 180), clipBlue),
        transform: const SegmentTransform(
          offset: Offset(320, 0),
          size: Size(320, 360),
          fit: SegmentFit.fill,
          rotation: math.pi,
        ),
      );

      final shown = await samplePixel(out, 0.88, 0.75);
      expect(isBlue(shown), isTrue, reason: 'Turned quarter: $shown');

      for (final p in const [
        Offset(0.62, 0.25), // where the quarter sits unturned
        Offset(0.62, 0.75),
        Offset(0.88, 0.25),
      ]) {
        final c = await samplePixel(out, p.dx, p.dy);
        expect(isRed(c), isTrue, reason: 'Expected the base at $p, got $c');
      }
    });
  });
}
