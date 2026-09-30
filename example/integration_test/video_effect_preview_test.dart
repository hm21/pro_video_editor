import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// Reads back the pixels `VideoEffectPreview` draws, so the preview shader is
/// checked on a real renderer, not just compiled.
///
/// The child is a flat grey, so every expected value follows from the spec in
/// `VideoEffectFrame` alone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const size = Size(64, 36);
  const darkGrey = Color(0xFF404040);

  Future<({ByteData data, int width})> preview(
    WidgetTester tester,
    List<VideoEffect> effects,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox.fromSize(
            size: size,
            child: VideoEffectPreview(
              effects: effects,
              position: ValueNotifier(Duration.zero),
              child: const ColoredBox(color: darkGrey),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final data = (await tester.runAsync(() async {
      final image = await boundary.toImage();
      return image.toByteData();
    }))!;
    return (data: data, width: size.width.toInt());
  }

  List<int> pixel(({ByteData data, int width}) frame, int x, int y) {
    final i = (y * frame.width + x) * 4;
    return [
      frame.data.getUint8(i),
      frame.data.getUint8(i + 1),
      frame.data.getUint8(i + 2),
    ];
  }

  group('VideoEffectPreview', () {
    setUpAll(() async {
      expect(
        await VideoEffectPreview.precache(),
        isTrue,
        reason: 'The preview shader needs Impeller',
      );
    });

    testWidgets('strobe fades the picture to white', (tester) async {
      final out = await preview(tester, const [VideoEffect.strobe()]);
      // A full flash at full intensity.
      expect(pixel(out, 32, 18), everyElement(greaterThanOrEqualTo(252)));
    });

    testWidgets('negativeFlash shows the negative', (tester) async {
      final out = await preview(tester, const [VideoEffect.negativeFlash()]);
      expect(pixel(out, 32, 18), everyElement(inInclusiveRange(189, 193)));
    });

    testWidgets('oldFilm tones grey towards sepia', (tester) async {
      final out = await preview(tester, const [VideoEffect.oldFilm()]);
      final rgb = pixel(out, 32, 18);
      expect(rgb[0], greaterThan(rgb[1]), reason: '$rgb');
      expect(rgb[1], greaterThan(rgb[2]), reason: '$rgb');
    });

    testWidgets('vignette keeps the center and darkens the corners', (
      tester,
    ) async {
      final out = await preview(tester, const [VideoEffect.vignette()]);
      expect(pixel(out, 32, 18), everyElement(inInclusiveRange(62, 66)));
      // Corner pixel (0, 0): 1 - 1.3 * t^2 is below 0, so it is black.
      expect(pixel(out, 0, 0), everyElement(inInclusiveRange(0, 2)));
      expect(pixel(out, 63, 35), pixel(out, 0, 0));
    });
  });
}
