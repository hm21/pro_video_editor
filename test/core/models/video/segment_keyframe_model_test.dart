import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/video/segment_keyframe_model.dart'
    show sortSegmentKeyframes;
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group(SegmentKeyframe, () {
    const keyframe = SegmentKeyframe(
      time: Duration(milliseconds: 1500),
      offset: Offset(0.25, -0.1),
      scale: 2.25,
      rotation: 1.2,
      curve: AnimationCurve.easeInOutCubic,
    );

    test('toMap writes the time in microseconds and the curve by name', () {
      final map = keyframe.toMap();

      expect(map['timeUs'], 1500000);
      expect(map['x'], 0.25);
      expect(map['y'], -0.1);
      expect(map['scale'], 2.25);
      expect(map['rotation'], 1.2);
      expect(map['curve'], 'easeInOutCubic');
    });

    test('fromMap restores what toMap writes', () {
      expect(SegmentKeyframe.fromMap(keyframe.toMap()), keyframe);
    });

    test('fromMap falls back to an unmoved, linear keyframe', () {
      final restored = SegmentKeyframe.fromMap(const {
        'timeUs': 40,
        'curve': 'unknown',
      });

      expect(restored.offset, Offset.zero);
      expect(restored.scale, 1);
      expect(restored.rotation, 0);
      expect(restored.curve, AnimationCurve.linear);
    });

    test('asserts the scale is not negative', () {
      expect(
        () => SegmentKeyframe(time: Duration.zero, scale: -1),
        throwsAssertionError,
      );
    });

    test('sortSegmentKeyframes orders by time and keeps equal times', () {
      const a = SegmentKeyframe(time: Duration(seconds: 2));
      const b = SegmentKeyframe(time: Duration(seconds: 1), scale: 2);
      const c = SegmentKeyframe(time: Duration(seconds: 1), scale: 3);

      expect(sortSegmentKeyframes([a, b, c]), [b, c, a]);
    });
  });

  group('VideoSegment.keyframes', () {
    const later = SegmentKeyframe(
      time: Duration(seconds: 2),
      offset: Offset(0.1, 0.2),
      scale: 2,
      curve: AnimationCurve.easeOut,
    );
    const earlier = SegmentKeyframe(time: Duration(milliseconds: 500));
    final segment = VideoSegment(
      video: EditorVideo.file('/tmp/clip.mp4'),
      startTime: const Duration(milliseconds: 250),
      keyframes: const [later, earlier],
    );

    test('default to none', () {
      expect(VideoSegment(video: EditorVideo.file('/a.mp4')).keyframes, []);
    });

    test('survive a JSON round trip', () {
      final restored = VideoSegment.fromJson(segment.toJson());

      expect(restored, segment);
      expect(restored.keyframes, [later, earlier]);
    });

    test('are sent to native sorted by time', () async {
      final map = await segment.toAsyncMap();

      expect(map['keyframes'], [earlier.toMap(), later.toMap()]);
    });

    test('are kept by copyWith', () {
      expect(segment.copyWith(volume: 0.5).keyframes, [later, earlier]);
    });

    test('make segments unequal when they differ', () {
      expect(segment.copyWith(keyframes: const [earlier]), isNot(segment));
    });
  });
}
