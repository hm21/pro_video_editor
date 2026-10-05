import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/image/layer_censor_model.dart';

void main() {
  group('LayerCensor', () {
    group('named constructors', () {
      test('blur carries its sigma as the strength', () {
        const censor = LayerCensor.blur(sigma: 12);

        expect(censor.type, LayerCensorType.blur);
        expect(censor.strength, 12);
      });

      test('pixelate carries its block size as the strength', () {
        const censor = LayerCensor.pixelate(blockSize: 48);

        expect(censor.type, LayerCensorType.pixelate);
        expect(censor.strength, 48);
      });
    });

    group('toMap / fromMap', () {
      test('roundtrip preserves type and strength', () {
        const censor = LayerCensor.pixelate(blockSize: 20);

        expect(LayerCensor.fromMap(censor.toMap()), censor);
      });

      test('falls back to the default strength when it is missing', () {
        expect(LayerCensor.fromMap({'type': 'blur'}), const LayerCensor.blur());
        expect(
          LayerCensor.fromMap({'type': 'pixelate', 'strength': 0}),
          const LayerCensor.pixelate(),
        );
      });

      test('throws on an unknown type', () {
        expect(
          () => LayerCensor.fromMap({'type': 'swirl', 'strength': 4}),
          throwsArgumentError,
        );
      });
    });

    test('toJson / fromJson roundtrip preserves data', () {
      const censor = LayerCensor.blur(sigma: 30);

      expect(LayerCensor.fromJson(censor.toJson()), censor);
    });

    test('copyWith replaces only the given fields', () {
      const censor = LayerCensor.blur(sigma: 30);

      expect(
        censor.copyWith(type: LayerCensorType.pixelate),
        const LayerCensor(type: LayerCensorType.pixelate, strength: 30),
      );
      expect(censor.copyWith(strength: 8), const LayerCensor.blur(sigma: 8));
    });

    test('tells censors apart by strength', () {
      expect(
        const LayerCensor.blur(sigma: 10),
        isNot(const LayerCensor.blur(sigma: 11)),
      );
    });

    test('rejects a strength that is not positive', () {
      expect(
        () => LayerCensor(type: LayerCensorType.blur, strength: 0),
        throwsAssertionError,
      );
    });
  });
}
