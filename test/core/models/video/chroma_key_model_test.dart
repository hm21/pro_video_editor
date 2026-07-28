import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('ChromaKey', () {
    const key = ChromaKey(
      color: Color(0xFF00FF00),
      similarity: 0.2,
      smoothness: 0.1,
      spill: 0.75,
      backgroundColor: Color(0xFFFF0000),
    );

    group('defaults', () {
      test('match the documented SMPTE green preset', () {
        const defaults = ChromaKey();

        expect(defaults.color, const Color(0xFF00B140));
        expect(defaults.similarity, 0.20);
        expect(defaults.smoothness, 0.08);
        expect(defaults.spill, 0.5);
        expect(defaults.backgroundColor, isNull);
        expect(defaults.backgroundImage, isNull);
      });

      test('are transparent, since no background is set', () {
        expect(const ChromaKey().isTransparent, isTrue);
      });
    });

    group('assertions', () {
      test('similarity must be greater than 0 and at most 1', () {
        expect(() => ChromaKey(similarity: 0), throwsA(isA<AssertionError>()));
        expect(
          () => ChromaKey(similarity: -0.1),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => ChromaKey(similarity: 1.1),
          throwsA(isA<AssertionError>()),
        );
        expect(const ChromaKey(similarity: 1).similarity, 1);
      });

      test('smoothness must be between 0 and 1', () {
        expect(() => ChromaKey(smoothness: -1), throwsA(isA<AssertionError>()));
        expect(() => ChromaKey(smoothness: 2), throwsA(isA<AssertionError>()));
        expect(const ChromaKey(smoothness: 0).smoothness, 0);
      });

      test('spill must be between 0 and 1', () {
        expect(() => ChromaKey(spill: -1), throwsA(isA<AssertionError>()));
        expect(() => ChromaKey(spill: 2), throwsA(isA<AssertionError>()));
        expect(const ChromaKey(spill: 0).spill, 0);
      });

      test('rejects two backgrounds at once', () {
        expect(
          () => ChromaKey(
            backgroundColor: const Color(0xFFFF0000),
            backgroundImage: EditorLayerImage.asset('assets/bg.png'),
          ),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    group('isTransparent', () {
      test('is false once a background is set', () {
        expect(
          const ChromaKey(backgroundColor: Color(0xFF123456)).isTransparent,
          isFalse,
        );
        expect(
          ChromaKey(
            backgroundImage: EditorLayerImage.asset('assets/bg.png'),
          ).isTransparent,
          isFalse,
        );
      });
    });

    group('toAsyncMap', () {
      test('serializes colors as ARGB ints for the platform channel', () async {
        final map = await key.toAsyncMap();

        expect(map['keyColor'], 0xFF00FF00);
        expect(map['similarity'], 0.2);
        expect(map['smoothness'], 0.1);
        expect(map['spill'], 0.75);
        expect(map['bgColor'], 0xFFFF0000);
        expect(map['bgImageData'], isNull);
      });

      test('sends null for both backgrounds when transparent', () async {
        final map = await const ChromaKey().toAsyncMap();

        expect(map['bgColor'], isNull);
        expect(map['bgImageData'], isNull);
      });

      test('resolves the background image to bytes', () async {
        final bytes = Uint8List.fromList([1, 2, 3, 4]);
        final map = await ChromaKey(
          backgroundImage: EditorLayerImage.memory(bytes),
        ).toAsyncMap();

        expect(map['bgImageData'], bytes);
      });
    });

    group('toMap / fromMap', () {
      test('serializes all fields correctly', () {
        final map = key.toMap();

        expect(map['color'], 0xFF00FF00);
        expect(map['similarity'], 0.2);
        expect(map['smoothness'], 0.1);
        expect(map['spill'], 0.75);
        expect(map['backgroundColor'], 0xFFFF0000);
        expect(map['backgroundImage'], isNull);
      });

      test('roundtrip preserves every field', () {
        final restored = ChromaKey.fromMap(key.toMap());

        expect(restored, key);
      });

      test('roundtrip preserves a transparent key', () {
        const transparent = ChromaKey();
        final restored = ChromaKey.fromMap(transparent.toMap());

        expect(restored, transparent);
        expect(restored.isTransparent, isTrue);
      });

      test('roundtrip preserves an asset background image', () {
        final withImage = ChromaKey(
          backgroundImage: EditorLayerImage.asset('assets/bg.png'),
        );
        final restored = ChromaKey.fromMap(withImage.toMap());

        expect(restored.backgroundImage?.assetPath, 'assets/bg.png');
      });

      test('falls back to the defaults for missing fields', () {
        final restored = ChromaKey.fromMap(const {});

        expect(restored, const ChromaKey());
      });

      test('parses numeric strings safely', () {
        final map = key.toMap()
          ..['similarity'] = '0.3'
          ..['spill'] = '1';

        final restored = ChromaKey.fromMap(map);
        expect(restored.similarity, 0.3);
        expect(restored.spill, 1.0);
      });

      test('json roundtrip preserves every field', () {
        expect(ChromaKey.fromJson(key.toJson()), key);
      });
    });

    group('copyWith', () {
      test('overrides only what is given', () {
        final copy = key.copyWith(similarity: 0.5);

        expect(copy.similarity, 0.5);
        expect(copy.color, key.color);
        expect(copy.smoothness, key.smoothness);
        expect(copy.spill, key.spill);
        expect(copy.backgroundColor, key.backgroundColor);
      });

      test('keeps every value when called empty', () {
        expect(key.copyWith(), key);
      });

      test('switching from an image background to a color drops the image', () {
        final withImage = key.copyWith(
          backgroundImage: EditorLayerImage.asset('assets/bg.png'),
        );
        expect(withImage.backgroundImage, isNotNull);
        expect(withImage.backgroundColor, isNull);

        final withColor = withImage.copyWith(
          backgroundColor: const Color(0xFF0000FF),
        );

        expect(withColor.backgroundColor, const Color(0xFF0000FF));
        expect(
          withColor.backgroundImage,
          isNull,
          reason:
              'the two are mutually exclusive, so setting one clears the '
              'other instead of tripping the assert',
        );
      });

      test('switching from a color background to an image drops the color', () {
        final copy = key.copyWith(
          backgroundImage: EditorLayerImage.asset('assets/bg.png'),
        );

        expect(copy.backgroundImage, isNotNull);
        expect(copy.backgroundColor, isNull);
      });

      test('removeBackground clears both and leaves the key transparent', () {
        final copy = key.copyWith(removeBackground: true);

        expect(copy.isTransparent, isTrue);
        expect(copy.backgroundColor, isNull);
        expect(copy.backgroundImage, isNull);
        expect(copy.color, key.color, reason: 'only the background is cleared');
        expect(copy.similarity, key.similarity);
      });

      test('removeBackground cannot be combined with a background', () {
        expect(
          () => key.copyWith(
            removeBackground: true,
            backgroundColor: const Color(0xFF00FF00),
          ),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    group('backgroundColor opacity', () {
      test('a translucent background is rejected when serialized', () {
        // Only RGB reaches either renderer, so a translucent fill would render
        // two different ways. Caught at the boundary rather than silently.
        const translucent = ChromaKey(backgroundColor: Color(0x80FF0000));

        expect(translucent.toAsyncMap(), throwsA(isA<AssertionError>()));
      });

      test('an opaque background serializes fine', () async {
        const opaque = ChromaKey(backgroundColor: Color(0xFFFF0000));

        await expectLater(opaque.toAsyncMap(), completes);
      });
    });

    group('equality', () {
      test('two identical keys are equal and share a hashCode', () {
        const a = ChromaKey(similarity: 0.3);
        const b = ChromaKey(similarity: 0.3);

        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('a differing parameter breaks equality', () {
        expect(const ChromaKey(similarity: 0.3), isNot(const ChromaKey()));
        expect(const ChromaKey(spill: 0.1), isNot(const ChromaKey()));
        expect(
          const ChromaKey(color: Color(0xFF0000FF)),
          isNot(const ChromaKey()),
        );
      });
    });

    test('toString includes every field', () {
      final text = key.toString();

      expect(text, contains('similarity: 0.2'));
      expect(text, contains('smoothness: 0.1'));
      expect(text, contains('spill: 0.75'));
    });
  });
}
