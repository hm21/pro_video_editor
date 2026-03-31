import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/video/export_transform_model.dart';

void main() {
  group('ExportTransform', () {
    group('toMap / fromMap', () {
      test('roundtrip with all fields', () {
        const transform = ExportTransform(
          rotateTurns: 2,
          flipX: true,
          flipY: true,
          width: 1920,
          height: 1080,
          x: 100,
          y: 200,
          scaleX: 1.5,
          scaleY: 0.75,
        );
        final map = transform.toMap();
        final restored = ExportTransform.fromMap(map);

        expect(restored.rotateTurns, 2);
        expect(restored.flipX, isTrue);
        expect(restored.flipY, isTrue);
        expect(restored.width, 1920);
        expect(restored.height, 1080);
        expect(restored.x, 100);
        expect(restored.y, 200);
        expect(restored.scaleX, 1.5);
        expect(restored.scaleY, 0.75);
      });

      test('roundtrip with defaults', () {
        const transform = ExportTransform();
        final map = transform.toMap();
        final restored = ExportTransform.fromMap(map);

        expect(restored.rotateTurns, 0);
        expect(restored.flipX, isFalse);
        expect(restored.flipY, isFalse);
        expect(restored.width, isNull);
        expect(restored.height, isNull);
        expect(restored.x, isNull);
        expect(restored.y, isNull);
        expect(restored.scaleX, isNull);
        expect(restored.scaleY, isNull);
      });

      test('fromMap parses string values via safe parsers', () {
        final map = <String, dynamic>{
          'rotateTurns': '1',
          'flipX': false,
          'flipY': true,
          'cropWidth': '800',
          'cropHeight': '600',
          'cropX': '50',
          'cropY': '25',
          'scaleX': '2.0',
          'scaleY': '0.5',
        };
        final restored = ExportTransform.fromMap(map);

        expect(restored.rotateTurns, 1);
        expect(restored.width, 800);
        expect(restored.height, 600);
        expect(restored.x, 50);
        expect(restored.y, 25);
        expect(restored.scaleX, 2.0);
        expect(restored.scaleY, 0.5);
      });

      test('toMap uses cropWidth/cropHeight/cropX/cropY keys', () {
        const transform = ExportTransform(
          width: 640,
          height: 480,
          x: 10,
          y: 20,
        );
        final map = transform.toMap();

        expect(map['cropWidth'], 640);
        expect(map['cropHeight'], 480);
        expect(map['cropX'], 10);
        expect(map['cropY'], 20);
      });
    });
  });
}
