import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('VideoSegment.stabilization', () {
    const stabilization = VideoStabilization(
      zoom: 1.05,
      keyframes: [
        StabilizationKeyframe(
          time: Duration(milliseconds: 33),
          offset: Offset(0.01, -0.02),
          rotation: 0.002,
          scale: 1.05,
        ),
        StabilizationKeyframe(time: Duration(milliseconds: 67), scale: 1.05),
      ],
    );
    final segment = VideoSegment(
      video: EditorVideo.file('/tmp/clip.mp4'),
      startTime: const Duration(milliseconds: 500),
      stabilization: stabilization,
    );

    test('survives a JSON round trip', () {
      final restored = VideoSegment.fromJson(segment.toJson());
      expect(restored, segment);
      expect(restored.stabilization, stabilization);
    });

    test('is sent to native as flat time and value lists', () {
      final map = segment.toMap()['stabilization'] as Map<String, dynamic>;
      expect(map['timesUs'], [33000, 67000]);
      expect(map['values'], [0.01, -0.02, 0.002, 1.05, 0.0, 0.0, 0.0, 1.05]);
    });

    test('is kept by copyWith', () {
      expect(segment.copyWith(volume: 0.5).stabilization, stabilization);
    });
  });
}
