import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group(TimelineKeyframe, () {
    const keyframe = TimelineKeyframe(
      time: Duration(milliseconds: 1500),
      offset: Offset(12.5, -40),
      scale: 2.25,
      rotation: 1.2,
      opacity: 0.4,
      curve: AnimationCurve.elasticOut,
    );

    test('toMap writes the time in microseconds and the curve by name', () {
      final map = keyframe.toMap();

      expect(map['timeUs'], 1500000);
      expect(map['x'], 12.5);
      expect(map['y'], -40);
      expect(map['curve'], 'elasticOut');
    });

    test('fromMap restores what toMap writes', () {
      expect(TimelineKeyframe.fromMap(keyframe.toMap()), keyframe);
    });

    test('fromMap falls back to an unscaled, opaque, linear keyframe', () {
      final restored = TimelineKeyframe.fromMap(const {
        'timeUs': 40,
        'x': 1,
        'y': 2,
        'curve': 'unknown',
      });

      expect(restored.scale, 1);
      expect(restored.rotation, 0);
      expect(restored.opacity, 1);
      expect(restored.curve, AnimationCurve.linear);
    });

    test('asserts the scale and opacity range', () {
      expect(
        () => TimelineKeyframe(
          time: Duration.zero,
          offset: Offset.zero,
          scale: -1,
        ),
        throwsAssertionError,
      );
      expect(
        () => TimelineKeyframe(
          time: Duration.zero,
          offset: Offset.zero,
          opacity: 1.5,
        ),
        throwsAssertionError,
      );
    });

    test('sortTimelineKeyframes orders by time', () {
      final later = keyframe.copyWith(time: const Duration(seconds: 3));
      final earlier = keyframe.copyWith(time: Duration.zero);

      expect(sortTimelineKeyframes([later, earlier]), [earlier, later]);
    });
  });
}
