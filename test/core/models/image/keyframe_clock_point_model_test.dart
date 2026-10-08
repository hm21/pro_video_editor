import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/image/keyframe_clock_point_model.dart';

void main() {
  group(KeyframeClockPoint, () {
    const point = KeyframeClockPoint(
      output: Duration(milliseconds: 1500),
      keyframe: Duration(seconds: 2),
    );

    test('toMap writes both times in microseconds', () {
      expect(point.toMap(), {'outputUs': 1500000, 'keyframeUs': 2000000});
    });

    test('fromMap reads what toMap wrote', () {
      expect(KeyframeClockPoint.fromMap(point.toMap()), point);
    });

    test('tells points apart by either time', () {
      expect(
        point,
        isNot(
          const KeyframeClockPoint(
            output: Duration(milliseconds: 1500),
            keyframe: Duration(milliseconds: 1500),
          ),
        ),
      );
      expect(
        point,
        isNot(
          const KeyframeClockPoint(
            output: Duration(seconds: 2),
            keyframe: Duration(seconds: 2),
          ),
        ),
      );
    });

    group('keyframeClockFromMap', () {
      test('reads a list of points', () {
        expect(keyframeClockFromMap([point.toMap()]), [point]);
      });

      test('reads no clock as none', () {
        expect(keyframeClockFromMap(null), isEmpty);
      });
    });
  });
}
