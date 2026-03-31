import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('VideoAudioTrack', () {
    final track = VideoAudioTrack(
      path: '/audio/music.mp3',
      volume: 0.8,
      loop: true,
      audioStartTime: const Duration(seconds: 5),
      audioEndTime: const Duration(seconds: 30),
      startTime: const Duration(seconds: 2),
      endTime: const Duration(seconds: 20),
    );

    group('toMap', () {
      test('serializes all fields correctly', () {
        final map = track.toMap();

        expect(map['path'], '/audio/music.mp3');
        expect(map['volume'], 0.8);
        expect(map['loop'], true);
        expect(map['audioStartTime'], 5000000);
        expect(map['audioEndTime'], 30000000);
        expect(map['startTime'], 2000000);
        expect(map['endTime'], 20000000);
      });

      test('serializes null durations as null', () {
        const minimal = VideoAudioTrack(path: '/audio.mp3');
        final map = minimal.toMap();

        expect(map['audioStartTime'], isNull);
        expect(map['audioEndTime'], isNull);
        expect(map['startTime'], isNull);
        expect(map['endTime'], isNull);
      });
    });

    group('fromMap', () {
      test('deserializes all fields correctly', () {
        final map = track.toMap();
        final restored = VideoAudioTrack.fromMap(map);

        expect(restored.path, track.path);
        expect(restored.volume, track.volume);
        expect(restored.loop, track.loop);
        expect(restored.audioStartTime, track.audioStartTime);
        expect(restored.audioEndTime, track.audioEndTime);
        expect(restored.startTime, track.startTime);
        expect(restored.endTime, track.endTime);
      });

      test('handles null durations', () {
        final restored = VideoAudioTrack.fromMap({
          'path': '/audio.mp3',
          'volume': 1.0,
          'loop': false,
          'audioStartTime': null,
          'audioEndTime': null,
          'startTime': null,
          'endTime': null,
        });

        expect(restored.audioStartTime, isNull);
        expect(restored.audioEndTime, isNull);
        expect(restored.startTime, isNull);
        expect(restored.endTime, isNull);
      });

      test('parses numeric strings safely', () {
        final restored = VideoAudioTrack.fromMap({
          'path': '/audio.mp3',
          'volume': '0.5',
          'loop': true,
          'audioStartTime': '1000000',
          'audioEndTime': null,
          'startTime': null,
          'endTime': null,
        });

        expect(restored.volume, 0.5);
        expect(restored.audioStartTime, const Duration(seconds: 1));
      });
    });

    group('toJson / fromJson', () {
      test('roundtrip preserves data', () {
        final json = track.toJson();
        final restored = VideoAudioTrack.fromJson(json);

        expect(restored, track);
      });
    });

    group('copyWith', () {
      test('creates copy with updated fields', () {
        final copy = track.copyWith(volume: 0.5, loop: false);

        expect(copy.volume, 0.5);
        expect(copy.loop, false);
        expect(copy.path, track.path);
        expect(copy.startTime, track.startTime);
      });

      test('preserves original when no args given', () {
        final copy = track.copyWith();
        expect(copy, track);
      });
    });

    group('equality', () {
      test('equal instances are equal', () {
        final other = VideoAudioTrack.fromMap(track.toMap());
        expect(other, track);
      });

      test('different instances are not equal', () {
        final other = track.copyWith(volume: 0.1);
        expect(other, isNot(track));
      });
    });

    test('toString contains class name', () {
      expect(track.toString(), contains('VideoAudioTrack'));
    });
  });
}
