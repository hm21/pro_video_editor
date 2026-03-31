import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('ColorFilter', () {
    final filter = ColorFilter(
      matrix: [
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0
      ],
      startTime: const Duration(seconds: 2),
      endTime: const Duration(seconds: 8),
    );

    group('toMap', () {
      test('serializes all fields correctly', () {
        final map = filter.toMap();

        expect(map['matrix'], filter.matrix);
        expect(map['startTime'], 2000000);
        expect(map['endTime'], 8000000);
      });

      test('serializes null durations as null', () {
        const minimal = ColorFilter(matrix: [1, 0, 0, 0, 0]);
        final map = minimal.toMap();

        expect(map['startTime'], isNull);
        expect(map['endTime'], isNull);
      });
    });

    group('fromMap', () {
      test('deserializes all fields correctly', () {
        final map = filter.toMap();
        final restored = ColorFilter.fromMap(map);

        expect(restored.matrix, filter.matrix);
        expect(restored.startTime, filter.startTime);
        expect(restored.endTime, filter.endTime);
      });

      test('handles null durations', () {
        final restored = ColorFilter.fromMap({
          'matrix': [1.0, 0.0],
          'startTime': null,
          'endTime': null,
        });

        expect(restored.startTime, isNull);
        expect(restored.endTime, isNull);
      });

      test('parses numeric strings safely', () {
        final restored = ColorFilter.fromMap({
          'matrix': [1.0, 0.0],
          'startTime': '5000000',
          'endTime': null,
        });

        expect(restored.startTime, const Duration(seconds: 5));
      });
    });

    group('toJson / fromJson', () {
      test('roundtrip preserves data', () {
        final json = filter.toJson();
        final restored = ColorFilter.fromJson(json);

        expect(restored, filter);
      });
    });

    group('copyWith', () {
      test('creates copy with updated fields', () {
        final copy = filter.copyWith(
          startTime: const Duration(seconds: 0),
        );

        expect(copy.startTime, Duration.zero);
        expect(copy.endTime, filter.endTime);
        expect(copy.matrix, filter.matrix);
      });
    });

    group('equality', () {
      test('equal instances are equal', () {
        final other = ColorFilter.fromMap(filter.toMap());
        expect(other, filter);
      });

      test('different instances are not equal', () {
        final other = filter.copyWith(
          startTime: const Duration(seconds: 5),
        );
        expect(other, isNot(filter));
      });
    });

    test('toString contains class name', () {
      expect(filter.toString(), contains('ColorFilter'));
    });
  });
}
