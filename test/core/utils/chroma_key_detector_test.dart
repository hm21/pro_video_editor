import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  const width = 80;
  const height = 60;

  /// Builds an RGBA frame: [screen] everywhere, with a [subject]-colored block
  /// covering the middle [subjectFraction] of the frame.
  Uint8List frame({
    required Color screen,
    Color? subject,
    double subjectFraction = 0.5,
    double lightingFalloff = 0,
  }) {
    final buffer = Uint8List(width * height * 4);
    final inset = (1 - subjectFraction) / 2;
    for (var y = 0; y < height; y++) {
      // Vertical brightness gradient, like a screen lit from the top.
      final dim = 1 - (y / height) * lightingFalloff;
      for (var x = 0; x < width; x++) {
        final inSubject =
            subject != null &&
            x >= width * inset &&
            x < width * (1 - inset) &&
            y >= height * inset &&
            y < height * (1 - inset);
        final c = inSubject ? subject : screen;
        final scale = inSubject ? 1.0 : dim;
        final i = (y * width + x) * 4;
        buffer[i] = ((c.r * 255) * scale).round().clamp(0, 255);
        buffer[i + 1] = ((c.g * 255) * scale).round().clamp(0, 255);
        buffer[i + 2] = ((c.b * 255) * scale).round().clamp(0, 255);
        buffer[i + 3] = 255;
      }
    }
    return buffer;
  }

  /// Builds an RGBA frame split vertically: [left] over the leftmost
  /// [leftFraction] of the width, [right] over the rest. Both reach the frame
  /// border, which is what the coverage test is there to catch.
  Uint8List splitFrame({
    required Color left,
    required Color right,
    double leftFraction = 0.5,
  }) {
    final buffer = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final c = x < width * leftFraction ? left : right;
        final i = (y * width + x) * 4;
        buffer[i] = (c.r * 255).round();
        buffer[i + 1] = (c.g * 255).round();
        buffer[i + 2] = (c.b * 255).round();
        buffer[i + 3] = 255;
      }
    }
    return buffer;
  }

  double chromaDistance(Color a, Color b) {
    final ca = ChromaKeyDetector.chromaOf(a.r, a.g, a.b);
    final cb = ChromaKeyDetector.chromaOf(b.r, b.g, b.b);
    return sqrt(pow(ca.cb - cb.cb, 2) + pow(ca.cr - cb.cr, 2));
  }

  group('ChromaKeyDetector', () {
    const green = Color(0xFF00B140);
    const blue = Color(0xFF0047BB);
    const skin = Color(0xFFC09070);

    test('finds a flat green screen behind a subject', () {
      final result = ChromaKeyDetector.fromFrames(
        [frame(screen: green, subject: skin)],
        width: width,
        height: height,
      );

      expect(chromaDistance(result.color, green), lessThan(0.01));
      expect(result.coverage, greaterThan(0.99));
      expect(result.spread, lessThan(0.01));
    });

    test('is hue-agnostic — a blue screen works the same', () {
      final result = ChromaKeyDetector.fromFrames(
        [frame(screen: blue, subject: skin)],
        width: width,
        height: height,
      );

      expect(chromaDistance(result.color, blue), lessThan(0.01));
      expect(result.coverage, greaterThan(0.99));
    });

    test('a flat screen still gets a workable soft margin', () {
      // A perfectly uniform synthetic screen has zero spread; the floor keeps
      // the key from being so tight that codec noise pokes through.
      final result = ChromaKeyDetector.fromFrames(
        [frame(screen: green, subject: skin)],
        width: width,
        height: height,
      );

      expect(result.similarity, greaterThanOrEqualTo(0.08));
    });

    test('the subject never decides the key', () {
      // The block covers most of the frame, but not the border ring.
      final result = ChromaKeyDetector.fromFrames(
        [frame(screen: green, subject: skin, subjectFraction: 0.7)],
        width: width,
        height: height,
      );

      expect(chromaDistance(result.color, green), lessThan(0.01));
      expect(chromaDistance(result.color, skin), greaterThan(0.3));
    });

    test('an unevenly lit screen widens similarity, not the color', () {
      final even = ChromaKeyDetector.fromFrames(
        [frame(screen: green, subject: skin)],
        width: width,
        height: height,
      );
      final uneven = ChromaKeyDetector.fromFrames(
        [frame(screen: green, subject: skin, lightingFalloff: 0.5)],
        width: width,
        height: height,
      );

      expect(
        uneven.spread,
        greaterThan(even.spread),
        reason: 'a falloff should show up as spread',
      );
      expect(
        uneven.similarity,
        greaterThan(even.similarity),
        reason: 'and similarity should widen to cover it',
      );
      // The hue did not change, only the brightness, so the detected color
      // stays on the same chroma direction.
      expect(chromaDistance(uneven.color, green), lessThan(0.08));
    });

    test('similarity covers the measured spread with margin', () {
      final result = ChromaKeyDetector.fromFrames(
        [frame(screen: green, subject: skin, lightingFalloff: 0.4)],
        width: width,
        height: height,
      );

      expect(result.similarity, greaterThanOrEqualTo(result.spread));
    });

    test('similarity is capped so a bad read cannot eat the subject', () {
      // A border that is half green and half a very different green-ish tone
      // produces a large spread; the cap keeps it from opening up wildly.
      final result = ChromaKeyDetector.fromFrames(
        [frame(screen: green, subject: skin, lightingFalloff: 0.9)],
        width: width,
        height: height,
      );

      expect(result.similarity, lessThanOrEqualTo(0.35));
    });

    test('pools several frames', () {
      final result = ChromaKeyDetector.fromFrames(
        [
          frame(screen: green, subject: skin),
          frame(screen: green, subject: skin),
          frame(screen: green, subject: skin),
        ],
        width: width,
        height: height,
      );

      expect(chromaDistance(result.color, green), lessThan(0.01));
    });

    group('rejects what is not a screen', () {
      test('a neutral border', () {
        expect(
          () => ChromaKeyDetector.fromFrames(
            [frame(screen: const Color(0xFF808080))],
            width: width,
            height: height,
          ),
          throwsA(
            isA<ChromaKeyDetectionException>().having(
              (e) => e.message,
              'message',
              contains('near-neutral'),
            ),
          ),
        );
      });

      test('a black border', () {
        expect(
          () => ChromaKeyDetector.fromFrames(
            [frame(screen: const Color(0xFF000000))],
            width: width,
            height: height,
          ),
          throwsA(isA<ChromaKeyDetectionException>()),
        );
      });

      test('no frames at all', () {
        expect(
          () => ChromaKeyDetector.fromFrames([], width: width, height: height),
          throwsA(isA<ChromaKeyDetectionException>()),
        );
      });

      test('a border that is half screen and half studio wall', () {
        // The regression this guards: coverage used to be derived from a
        // percentile of the very distances it was measuring, so it came out
        // at ~99% for any frame at all and this never threw.
        expect(
          () => ChromaKeyDetector.fromFrames(
            [splitFrame(left: green, right: const Color(0xFF8B5A2B))],
            width: width,
            height: height,
          ),
          throwsA(
            isA<ChromaKeyDetectionException>().having(
              (e) => e.message,
              'message',
              contains('one color'),
            ),
          ),
        );
      });

      test('a border that is half screen and half red curtain', () {
        expect(
          () => ChromaKeyDetector.fromFrames(
            [splitFrame(left: green, right: const Color(0xFFCC2222))],
            width: width,
            height: height,
          ),
          throwsA(isA<ChromaKeyDetectionException>()),
        );
      });

      test('coverage is a real measurement, not a constant', () {
        // A minority of off-screen pixels is tolerated, but it has to show up
        // in `coverage` — the old implementation reported ~1.0 regardless.
        final result = ChromaKeyDetector.fromFrames(
          [splitFrame(left: green, right: skin, leftFraction: 0.8)],
          width: width,
          height: height,
        );

        expect(result.coverage, lessThan(0.95));
        expect(result.coverage, greaterThan(0.6));
        expect(chromaDistance(result.color, green), lessThan(0.01));
      });

      test('a buffer that is too small for the stated size', () {
        expect(
          () => ChromaKeyDetector.fromFrames(
            [Uint8List(10)],
            width: width,
            height: height,
          ),
          throwsA(
            isA<ChromaKeyDetectionException>().having(
              (e) => e.message,
              'message',
              contains('expected at least'),
            ),
          ),
        );
      });
    });

    test('chromaOf matches the renderers\' BT.601 formula', () {
      // Pinned against the same constants the shader and the color cube use.
      final c = ChromaKeyDetector.chromaOf(0, 0xB1 / 255, 0x40 / 255);
      expect(c.cb, closeTo(-0.1044, 1e-4));
      expect(c.cr, closeTo(-0.3110, 1e-4));
    });

    test('a neutral color sits at the chroma origin', () {
      final c = ChromaKeyDetector.chromaOf(0.5, 0.5, 0.5);
      expect(c.cb, closeTo(0, 1e-9));
      expect(c.cr, closeTo(0, 1e-9));
    });
  });

  group('ChromaKey presets', () {
    test('greenScreen matches the default constructor', () {
      const preset = ChromaKey.greenScreen();
      const plain = ChromaKey();

      expect(preset.color, plain.color);
      expect(preset.similarity, plain.similarity);
      expect(preset.spill, plain.spill);
    });

    test('blueScreen keys tighter and despills more gently', () {
      const green = ChromaKey.greenScreen();
      const blue = ChromaKey.blueScreen();

      expect(blue.color, const Color(0xFF0047BB));
      expect(
        blue.similarity,
        lessThan(green.similarity),
        reason: 'denim sits at 0.19 from blue, inside the green default',
      );
      expect(blue.spill, lessThan(green.spill));
    });

    test('the blue preset does not key denim', () {
      const blue = ChromaKey.blueScreen();
      const denim = Color(0xFF3B5B8C);

      final d = chromaDistance(blue.color, denim);
      expect(
        d,
        greaterThan(blue.similarity),
        reason: 'denim ($d) must sit outside similarity (${blue.similarity})',
      );
    });

    test('the green default would key denim on a blue screen', () {
      // The reason blueScreen exists as its own preset.
      const denim = Color(0xFF3B5B8C);
      final d = chromaDistance(const Color(0xFF0047BB), denim);

      expect(d, lessThan(const ChromaKey.greenScreen().similarity));
    });

    test('presets carry a background through', () {
      const key = ChromaKey.blueScreen(backgroundColor: Color(0xFFFF0000));

      expect(key.isTransparent, isFalse);
      expect(key.backgroundColor, const Color(0xFFFF0000));
    });

    test('presets keep the shared assertions', () {
      expect(
        () => ChromaKey.blueScreen(similarity: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => ChromaKey.greenScreen(spill: 2),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
