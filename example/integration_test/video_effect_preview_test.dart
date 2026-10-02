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
    List<VideoEffect> effects, {
    Widget child = const ColoredBox(color: darkGrey),
  }) async {
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
              child: child,
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

    // A white column, x = 8..15, on black.
    const stripe = Stack(
      textDirection: TextDirection.ltr,
      children: [
        ColoredBox(color: Color(0xFF000000), child: SizedBox.expand()),
        Positioned(
          left: 8,
          top: 0,
          bottom: 0,
          width: 8,
          child: ColoredBox(color: Color(0xFFFFFFFF)),
        ),
      ],
    );

    testWidgets('mirror shows the left half mirrored on the right', (
      tester,
    ) async {
      final out = await preview(tester, const [
        VideoEffect.mirror(),
      ], child: stripe);
      // Columns 8..15 mirror onto 48..55.
      expect(pixel(out, 12, 18), everyElement(greaterThanOrEqualTo(250)));
      expect(pixel(out, 51, 18), everyElement(greaterThanOrEqualTo(250)));
      expect(pixel(out, 32, 18), everyElement(lessThanOrEqualTo(5)));
      expect(pixel(out, 60, 18), everyElement(lessThanOrEqualTo(5)));
    });

    testWidgets('splitScreen repeats the picture at half size', (tester) async {
      final out = await preview(tester, const [
        VideoEffect.splitScreen(),
      ], child: stripe);
      // The column lands at 4..7 in the left copies and 36..39 in the right.
      for (final (x, y) in [(5, 9), (37, 9), (6, 27), (38, 27)]) {
        expect(pixel(out, x, y), everyElement(greaterThanOrEqualTo(250)));
      }
      expect(pixel(out, 12, 9), everyElement(lessThanOrEqualTo(5)));
      expect(pixel(out, 44, 27), everyElement(lessThanOrEqualTo(5)));
    });

    testWidgets('wave moves rows sideways', (tester) async {
      final out = await preview(tester, const [
        VideoEffect.wave(),
      ], child: stripe);
      // Half the frame tall: the crest is at row 4, the trough at row 13,
      // where the column moves 1.6 pixels right and left of where it is on
      // row 9, close to where the wave crosses zero.
      expect(pixel(out, 6, 4)[0], lessThan(pixel(out, 6, 9)[0]));
      expect(pixel(out, 16, 4)[0], greaterThan(pixel(out, 16, 9)[0]));
      expect(pixel(out, 5, 13)[0], greaterThan(pixel(out, 5, 9)[0]));
      expect(pixel(out, 14, 13)[0], lessThan(pixel(out, 14, 9)[0]));
    });

    testWidgets('glow spreads a white column into the black beside it', (
      tester,
    ) async {
      // A white column, x = 24..39, on black.
      const column = Stack(
        textDirection: TextDirection.ltr,
        children: [
          ColoredBox(color: Color(0xFF000000), child: SizedBox.expand()),
          Positioned(
            left: 24,
            top: 0,
            bottom: 0,
            width: 16,
            child: ColoredBox(color: Color(0xFFFFFFFF)),
          ),
        ],
      );
      final plain = await preview(tester, const [], child: column);
      final out = await preview(tester, const [
        VideoEffect.glow(),
      ], child: column);
      expect(pixel(plain, 22, 18), everyElement(lessThanOrEqualTo(2)));
      // A blur of 0.025 * 36 = 0.9 pixels: the glow reaches only the pixels
      // right next to the column.
      expect(pixel(out, 23, 18), everyElement(greaterThan(20)));
      expect(pixel(out, 40, 18), everyElement(greaterThan(20)));
      expect(pixel(out, 10, 18), everyElement(lessThanOrEqualTo(8)));
      expect(pixel(out, 32, 18), everyElement(greaterThanOrEqualTo(250)));
    });
  });
}
