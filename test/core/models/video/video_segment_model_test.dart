import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('VideoSegment', () {
    final video = EditorVideo.asset('assets/test.mp4');
    final segment = VideoSegment(
      video: video,
      startTime: const Duration(seconds: 2),
      endTime: const Duration(seconds: 10),
      volume: 0.8,
    );

    group('toMap', () {
      test('serializes all fields correctly', () {
        final map = segment.toMap();

        expect(map['video'], isA<Map<String, dynamic>>());
        expect(map['startTime'], 2000000);
        expect(map['endTime'], 10000000);
        expect(map['volume'], 0.8);
        expect(map['reverseVideo'], isFalse);
      });

      test('serializes reverseVideo correctly', () {
        final reversed = VideoSegment(video: video, reverseVideo: true);
        final map = reversed.toMap();

        expect(map['reverseVideo'], isTrue);
      });

      test('serializes null fields as null', () {
        final minimal = VideoSegment(video: video);
        final map = minimal.toMap();

        expect(map['startTime'], isNull);
        expect(map['endTime'], isNull);
        expect(map['volume'], isNull);
        expect(map['reverseVideo'], isFalse);
      });
    });

    group('fromMap', () {
      test('deserializes all fields correctly', () {
        final map = segment.toMap();
        final restored = VideoSegment.fromMap(map);

        expect(restored.video, segment.video);
        expect(restored.startTime, segment.startTime);
        expect(restored.endTime, segment.endTime);
        expect(restored.volume, segment.volume);
        expect(restored.reverseVideo, segment.reverseVideo);
      });

      test('handles null optional fields', () {
        final minimal = VideoSegment(video: video);
        final map = minimal.toMap();
        final restored = VideoSegment.fromMap(map);

        expect(restored.startTime, isNull);
        expect(restored.endTime, isNull);
        expect(restored.volume, isNull);
        expect(restored.reverseVideo, isFalse);
      });

      test('deserializes reverseVideo correctly', () {
        final restored = VideoSegment.fromMap({
          'video': {'assetPath': 'assets/test.mp4'},
          'reverseVideo': true,
        });

        expect(restored.reverseVideo, isTrue);
      });

      test('parses numeric strings safely', () {
        final restored = VideoSegment.fromMap({
          'video': {'assetPath': 'assets/test.mp4'},
          'startTime': '3000000',
          'endTime': null,
          'volume': '0.5',
        });

        expect(restored.startTime, const Duration(seconds: 3));
        expect(restored.volume, 0.5);
      });
    });

    group('toJson / fromJson', () {
      test('roundtrip preserves data', () {
        final json = segment.toJson();
        final restored = VideoSegment.fromJson(json);

        expect(restored, segment);
      });
    });

    group('copyWith', () {
      test('creates copy with updated fields', () {
        final copy = segment.copyWith(volume: 1.5, reverseVideo: true);

        expect(copy.volume, 1.5);
        expect(copy.reverseVideo, isTrue);
        expect(copy.video, segment.video);
        expect(copy.startTime, segment.startTime);
      });

      test('preserves original when no args given', () {
        final copy = segment.copyWith();
        expect(copy, segment);
      });
    });

    group('equality', () {
      test('equal instances are equal', () {
        final other = VideoSegment.fromMap(segment.toMap());
        expect(other, segment);
      });

      test('different instances are not equal', () {
        final other = segment.copyWith(volume: 0.1);
        expect(other, isNot(segment));
      });
    });

    test('toString contains class name', () {
      expect(segment.toString(), contains('VideoSegment'));
    });
  });
}
