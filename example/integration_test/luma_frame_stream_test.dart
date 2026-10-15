import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

/// 640x360 stored, displayed turned to portrait.
const _rotated = 'assets/tests/test_g.mp4';

/// On-device behaviour of `getLumaFrameStream`: every frame of the range
/// arrives once, upright and in presentation order, and feeds the
/// stabilization analysis.
/// H.264 assets throughout: the emulator's software decoder cannot decode the
/// 10-bit HEVC of `hevc.mp4`, and every device decodes these.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  const box = ui.Size(320, 320);

  Future<List<LumaFrame>> collect(LumaFrameConfigs configs) =>
      pve.getLumaFrameStream(configs).toList();

  /// The thumbnail of the same instant decoded to luma, as the reference for
  /// orientation.
  Future<Uint8List> thumbnailLuma(
    EditorVideo video,
    Duration time,
    int width,
    int height,
  ) async {
    final jpeg = await pve
        .getThumbnailStream(
          ThumbnailConfigs(
            video: video,
            outputSize: ui.Size(width.toDouble(), height.toDouble()),
            boxFit: ThumbnailBoxFit.contain,
            outputFormat: ThumbnailFormat.png,
            timestamps: [time],
          ),
        )
        .first;
    final codec = await ui.instantiateImageCodec(jpeg.bytes);
    final image = (await codec.getNextFrame()).image;
    expect(image.width, width);
    expect(image.height, height);
    final rgba = (await image.toByteData())!.buffer.asUint8List();
    final luma = Uint8List(width * height);
    for (var i = 0; i < luma.length; i++) {
      luma[i] =
          (rgba[4 * i] * 77 + rgba[4 * i + 1] * 150 + rgba[4 * i + 2] * 29) >>
          8;
    }
    return luma;
  }

  /// Normalized cross-correlation: 1 for the same picture regardless of
  /// brightness and contrast. The raw luma of an HDR clip is not tone-mapped
  /// the way a thumbnail is, so plain pixel differences would mislead.
  double correlation(Uint8List a, Uint8List b) {
    double mean(Uint8List v) => v.fold<int>(0, (s, x) => s + x) / v.length;
    final ma = mean(a);
    final mb = mean(b);
    var ab = 0.0, aa = 0.0, bb = 0.0;
    for (var i = 0; i < a.length; i++) {
      final da = a[i] - ma;
      final db = b[i] - mb;
      ab += da * db;
      aa += da * da;
      bb += db * db;
    }
    return ab / sqrt(aa * bb);
  }

  Uint8List mirrored(Uint8List v, int width, int height) => Uint8List.fromList([
    for (var y = 0; y < height; y++)
      for (var x = width - 1; x >= 0; x--) v[y * width + x],
  ]);

  group('getLumaFrameStream', () {
    test(
      'delivers every frame upright, in order, with its timestamp',
      () async {
        final frames = await collect(
          LumaFrameConfigs(video: EditorVideo.asset(_rotated), outputSize: box),
        );

        // test_g.mp4 holds 60 frames of 640x360, displayed turned to portrait.
        expect(frames, hasLength(60));
        for (var i = 0; i < frames.length; i++) {
          final frame = frames[i];
          expect(frame.width, 180);
          expect(frame.height, 320);
          expect(frame.bytes, hasLength(180 * 320));
          if (i > 0) expect(frame.time, greaterThan(frames[i - 1].time));
          if (i > 0) {
            expect(
              frame.progress,
              greaterThanOrEqualTo(frames[i - 1].progress),
            );
          }
        }
        expect(frames.last.progress, closeTo(1, 1e-3));
      },
    );

    test('keeps the orientation the thumbnails show', () async {
      for (final path in [
        _rotated,
        'assets/tests/test_b.mp4',
        kVideoEditorExampleDivinePath,
      ]) {
        final video = EditorVideo.asset(path);
        final frames = await collect(
          LumaFrameConfigs(
            video: video,
            outputSize: box,
            startTime: const Duration(milliseconds: 500),
            endTime: const Duration(milliseconds: 600),
          ),
        );
        final frame = frames.first;
        final reference = await thumbnailLuma(
          video,
          frame.time,
          frame.width,
          frame.height,
        );
        final match = correlation(frame.bytes, reference);
        expect(match, greaterThan(0.8), reason: '$path at ${frame.time}');
        expect(
          match,
          greaterThan(
            correlation(
                  mirrored(frame.bytes, frame.width, frame.height),
                  reference,
                ) +
                0.1,
          ),
          reason: '$path is mirrored',
        );
      }
    });

    test('keeps to the range and the frame rate cap', () async {
      // test_c.mp4 runs at 60 fps.
      final frames = await collect(
        LumaFrameConfigs(
          video: EditorVideo.asset('assets/tests/test_c.mp4'),
          outputSize: box,
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 2),
          maxFrameRate: 30,
        ),
      );
      expect(frames.length, inInclusiveRange(29, 31));
      expect(
        frames.first.time,
        greaterThanOrEqualTo(const Duration(seconds: 1)),
      );
      expect(frames.last.time, lessThan(const Duration(seconds: 2)));
      for (var i = 1; i < frames.length; i++) {
        expect(
          frames[i].time - frames[i - 1].time,
          greaterThanOrEqualTo(const Duration(milliseconds: 32)),
        );
      }
    });

    test('feeds the stabilization analysis', () async {
      final watch = Stopwatch()..start();
      VideoStabilizationAnalyzer? analyzer;
      await for (final frame in pve.getLumaFrameStream(
        LumaFrameConfigs(
          video: EditorVideo.asset(kVideoEditorExampleDivinePath),
          outputSize: box,
        ),
      )) {
        analyzer ??= VideoStabilizationAnalyzer(
          width: frame.width,
          height: frame.height,
        );
        analyzer.addFrame(frame.bytes, frame.time);
      }
      final result = analyzer!.finish();
      // ignore: avoid_print
      print(
        'stabilization of divine_transcribed.mp4: '
        '${watch.elapsedMilliseconds} ms, '
        'zoom ${result.zoom.toStringAsFixed(3)}, '
        'unreliable ${result.unreliableFrames}',
      );
      // divine_transcribed.mp4 holds 169 frames.
      expect(result.keyframes, hasLength(169));
      expect(result.zoom, inInclusiveRange(1.0, 1.15));
    });
  });
}
