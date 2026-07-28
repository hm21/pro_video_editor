import 'dart:ui';

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

    group('chromaKey', () {
      const key = ChromaKey(
        similarity: 0.3,
        backgroundColor: Color(0xFF0000FF),
      );

      test('defaults to null so the clip inherits the layer/global key', () {
        expect(segment.chromaKey, isNull);
      });

      // toAsyncMap resolves the source to a local path, so these use a file
      // video — an asset would need the platform channel.
      final local = VideoSegment(video: EditorVideo.file('test.mp4'));

      test('toAsyncMap sends the key over the platform channel', () async {
        final map = await local.copyWith(chromaKey: key).toAsyncMap();

        expect(map['chromaKey'], isA<Map<String, dynamic>>());
        expect((map['chromaKey'] as Map)['similarity'], 0.3);
      });

      test('toAsyncMap omits the key when unset', () async {
        expect((await local.toAsyncMap())['chromaKey'], isNull);
      });

      test('toMap / fromMap roundtrip preserves the key', () {
        final withKey = segment.copyWith(chromaKey: key);

        expect(VideoSegment.fromMap(withKey.toMap()).chromaKey, key);
        expect(VideoSegment.fromMap(segment.toMap()).chromaKey, isNull);
      });

      test('copyWith overrides and otherwise keeps the key', () {
        final withKey = segment.copyWith(chromaKey: key);

        expect(withKey.copyWith().chromaKey, key);
        expect(
          withKey.copyWith(chromaKey: const ChromaKey()).chromaKey,
          const ChromaKey(),
        );
      });

      test('a differing key breaks equality', () {
        expect(segment.copyWith(chromaKey: key), isNot(segment));
      });
    });
  });
}
