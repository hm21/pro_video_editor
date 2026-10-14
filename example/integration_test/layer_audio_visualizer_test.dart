import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// End-to-end verification that an audio visualizer layer draws in the
/// export what [AudioVisualizerPainter] draws in an editor, follows its
/// levels over time, and takes its place and rotation from the layer, on the
/// platform the test runs on.
///
/// The visualizer is drawn in green over a black clip, so every pixel is
/// known. Values stay tolerant of codec rounding.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  const canvas = Size(640, 360);
  const box = Rect.fromLTWH(64, 40, 512, 280);
  const green = Color(0xFF00FF00);

  late EditorVideo black;

  setUpAll(() async {
    final recorder = PictureRecorder();
    Canvas(
      recorder,
    ).drawRect(Offset.zero & canvas, Paint()..color = const Color(0xFF000000));
    final image = await recorder.endRecording().toImage(
      canvas.width.toInt(),
      canvas.height.toInt(),
    );
    final png = (await image.toByteData(format: ImageByteFormat.png))!;
    final bytes = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [
          // A two-second clip.
          VideoSegment(video: EditorVideo.asset('assets/tests/test_d.mp4')),
        ],
        imageLayers: [
          ImageLayer(image: EditorLayerImage.memory(png.buffer.asUint8List())),
        ],
        transform: ExportTransform(
          width: canvas.width.toInt(),
          height: canvas.height.toInt(),
        ),
      ),
    );
    black = EditorVideo.memory(bytes);
  });

  /// A table of [bandCount] bands, ten rows a second for three seconds, whose
  /// row at time `t` seconds is `levels(t)`.
  LayerAudioVisualizer visualizer(
    AudioVisualizerStyle style,
    int bandCount,
    List<double> Function(double seconds) levels, {
    double? barFill,
  }) {
    return LayerAudioVisualizer(
      style: style,
      color: green,
      bandCount: bandCount,
      framesPerSecond: 10,
      barFill: barFill,
      levels: Float32List.fromList([
        for (var row = 0; row < 30; row++) ...levels(row / 10),
      ]),
    );
  }

  Future<Uint8List> render(ImageLayer layer) {
    return pve.renderVideo(
      VideoRenderData(
        videoSegments: [VideoSegment(video: black)],
        imageLayers: [layer],
      ),
    );
  }

  /// The RGBA pixels of the frame of [video] at [at].
  Future<({ByteData data, int width})> frameOf(
    Uint8List video, [
    Duration at = const Duration(milliseconds: 500),
  ]) async {
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
    expect(image.width, canvas.width.toInt());
    return (data: (await image.toByteData())!, width: image.width);
  }

  bool isGreen(({ByteData data, int width}) frame, int x, int y) {
    final i = (y * frame.width + x) * 4;
    return frame.data.getUint8(i + 1) > 160 && frame.data.getUint8(i) < 90;
  }

  bool isBlack(({ByteData data, int width}) frame, int x, int y) {
    final i = (y * frame.width + x) * 4;
    return frame.data.getUint8(i + 1) < 60;
  }

  testWidgets('draws a loud band as a full bar and a silent one as a dot', (
    tester,
  ) async {
    final out = await frameOf(
      await render(
        ImageLayer.audioVisualizer(
          visualizer: visualizer(AudioVisualizerStyle.bars, 2, (_) => [1, 0]),
          offset: box.topLeft,
          size: box.size,
        ),
      ),
    );

    // The left slot is x 64..320, its bar x 102..282.
    expect(isGreen(out, 192, 60), isTrue, reason: 'top of the loud bar');
    expect(isGreen(out, 192, 300), isTrue, reason: 'bottom of the loud bar');
    // The right bar is a dot 180 px tall at the bottom of the box.
    expect(isBlack(out, 448, 60), isTrue, reason: 'above the silent bar');
    expect(isGreen(out, 448, 300), isTrue, reason: 'the silent bar\'s dot');
    // The gap between the bars and the frame outside the box stay black.
    expect(isBlack(out, 320, 180), isTrue, reason: 'gap between the bars');
    expect(isBlack(out, 30, 180), isTrue, reason: 'left of the box');
  });

  testWidgets('follows its levels over time on the rendered video', (
    tester,
  ) async {
    // Four bands, the first loud for a second and then silent: its bar,
    // x 83..173, fills the box and then shrinks to a dot at the bottom.
    final video = await render(
      ImageLayer.audioVisualizer(
        visualizer: visualizer(
          AudioVisualizerStyle.bars,
          4,
          (seconds) => [if (seconds < 1) 1 else 0, 0, 0, 0],
        ),
        offset: box.topLeft,
        size: box.size,
      ),
    );

    final loud = await frameOf(video, const Duration(milliseconds: 500));
    final quiet = await frameOf(video, const Duration(milliseconds: 1500));
    expect(isGreen(loud, 128, 60), isTrue);
    expect(isBlack(quiet, 128, 60), isTrue);
    expect(isGreen(quiet, 128, 300), isTrue);
  });

  testWidgets('shows only inside its time range', (tester) async {
    final video = await render(
      ImageLayer.audioVisualizer(
        visualizer: visualizer(AudioVisualizerStyle.bars, 1, (_) => [1]),
        offset: box.topLeft,
        size: box.size,
        startTime: const Duration(seconds: 1),
      ),
    );

    expect(isBlack(await frameOf(video), 320, 180), isTrue);
    expect(
      isGreen(
        await frameOf(video, const Duration(milliseconds: 1500)),
        320,
        180,
      ),
      isTrue,
    );
  });

  testWidgets('turns with the layer', (tester) async {
    // A bar layer 280 px wide and 120 px tall, turned upright by 90°: one
    // loud band fills the middle of its slot, which then runs top to bottom.
    final out = await frameOf(
      await render(
        ImageLayer.audioVisualizer(
          visualizer: visualizer(AudioVisualizerStyle.bars, 1, (_) => [1]),
          offset: const Offset(180, 120),
          size: const Size(280, 120),
          rotation: 1.5707963,
        ),
      ),
    );

    // The box's center is (320, 180). Upright, the bar is x 222..418 and
    // y 120..240; turned, it is x 260..380 and y 82..278.
    expect(isGreen(out, 320, 100), isTrue, reason: 'top of the turned bar');
    expect(isGreen(out, 320, 260), isTrue, reason: 'bottom of the turned bar');
    expect(isBlack(out, 230, 180), isTrue, reason: 'left of the turned bar');
    expect(isBlack(out, 410, 180), isTrue, reason: 'right of the turned bar');
  });

  testWidgets('fills the frame when stretched, whatever its size', (
    tester,
  ) async {
    // One loud band of a ring is two bars, pointing right and left from the
    // middle of the frame. The ring fits the frame's height, radius 180:
    // each bar runs from 90 to 180 px out, 45 px wide, so the right one is
    // x 410..500. Drawn in a 100 x 100 box and stretched over the frame, it
    // would run x 480..640 instead.
    for (final size in [null, const Size(100, 100)]) {
      final out = await frameOf(
        await render(
          ImageLayer.audioVisualizer(
            visualizer: visualizer(AudioVisualizerStyle.circle, 1, (_) => [1]),
            size: size,
          ),
        ),
      );

      expect(isGreen(out, 430, 180), isTrue, reason: 'right bar, size $size');
      expect(isGreen(out, 210, 180), isTrue, reason: 'left bar, size $size');
      expect(isBlack(out, 320, 180), isTrue, reason: 'ring, size $size');
      expect(isBlack(out, 600, 180), isTrue, reason: 'past the bar, $size');
    }
  });

  testWidgets('moves and grows with its keyframes', (tester) async {
    // A 160 x 90 box that one keyframe puts at the middle of the frame,
    // grown twice: x 160..480 and y 90..270, its loud bar x 208..432. At its
    // own size the bar would be x 264..376 and y 135..225.
    final out = await frameOf(
      await render(
        ImageLayer.audioVisualizer(
          visualizer: visualizer(AudioVisualizerStyle.bars, 1, (_) => [1]),
          offset: Offset.zero,
          size: const Size(160, 90),
          keyframes: const [
            TimelineKeyframe(
              time: Duration.zero,
              offset: Offset(240, 135),
              scale: 2,
            ),
          ],
        ),
      ),
    );

    expect(isGreen(out, 320, 100), isTrue, reason: 'top of the grown bar');
    expect(isGreen(out, 320, 260), isTrue, reason: 'bottom of the grown bar');
    expect(isGreen(out, 220, 180), isTrue, reason: 'left of the grown bar');
    expect(isBlack(out, 320, 80), isTrue, reason: 'above the grown box');
    expect(isBlack(out, 40, 40), isTrue, reason: 'where the offset was');
  });

  group('matches the editor preview', () {
    /// The editor preview of [layer]'s visualizer at 0.5 s: its alpha, one
    /// value per pixel of the box.
    Future<Uint8List> previewAlpha(LayerAudioVisualizer visualizer) async {
      final recorder = PictureRecorder();
      AudioVisualizerPainter.at(
        visualizer,
        const Duration(milliseconds: 500),
      ).paint(Canvas(recorder), box.size);
      final image = await recorder.endRecording().toImage(
        box.width.toInt(),
        box.height.toInt(),
      );
      final rgba = (await image.toByteData())!;
      return Uint8List.fromList([
        for (var i = 3; i < rgba.lengthInBytes; i += 4) rgba.getUint8(i),
      ]);
    }

    for (final (style, barFill) in [
      for (final style in AudioVisualizerStyle.values) (style, null),
      (AudioVisualizerStyle.bars, 0.35),
      (AudioVisualizerStyle.circle, 0.45),
    ]) {
      testWidgets('for ${style.name}'
          '${barFill == null ? '' : ' with a bar fill of $barFill'}', (
        tester,
      ) async {
        final layerVisualizer = visualizer(
          style,
          8,
          (_) => [0.9, 0.2, 0.6, 1, 0.1, 0.45, 0.75, 0.3],
          barFill: barFill,
        );
        final out = await frameOf(
          await render(
            ImageLayer.audioVisualizer(
              visualizer: layerVisualizer,
              offset: box.topLeft,
              size: box.size,
            ),
          ),
        );
        final alpha = await previewAlpha(layerVisualizer);
        final width = box.width.toInt();
        final height = box.height.toInt();

        // Compared on a grid, skipping points near an edge of a shape,
        // where antialiasing and the codec blur the two apart.
        bool uniform(int x, int y) {
          final value = alpha[y * width + x];
          for (var dy = -4; dy <= 4; dy++) {
            for (var dx = -4; dx <= 4; dx++) {
              final nx = (x + dx).clamp(0, width - 1);
              final ny = (y + dy).clamp(0, height - 1);
              if (alpha[ny * width + nx] != value) return false;
            }
          }
          return value == 0 || value == 255;
        }

        var compared = 0;
        var filled = 0;
        final mismatches = <String>[];
        for (var y = 2; y < height; y += 6) {
          for (var x = 2; x < width; x += 6) {
            if (!uniform(x, y)) continue;
            compared++;
            final inPreview = alpha[y * width + x] == 255;
            if (inPreview) filled++;
            final fx = box.left.toInt() + x;
            final fy = box.top.toInt() + y;
            final inExport = inPreview
                ? isGreen(out, fx, fy)
                : isBlack(out, fx, fy);
            if (!inExport) mismatches.add('($x, $y)');
          }
        }
        expect(compared, greaterThan(500));
        expect(filled, greaterThan(10), reason: 'the preview drew nothing');
        expect(
          mismatches.length,
          lessThanOrEqualTo(compared ~/ 100),
          reason: 'export differs from the preview at $mismatches',
        );
      });
    }
  });
}
