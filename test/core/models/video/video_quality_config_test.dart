import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('VideoQualityConfig', () {
    test('creates 4K preset with correct values', () {
      final config = VideoQualityConfig.fromPreset(VideoQualityPreset.k4);

      expect(config.bitrate, equals(35000000)); // 35 Mbps
      expect(config.resolution, equals(const Size(3840, 2160)));
      expect(config.preset, equals(VideoQualityPreset.k4));
    });

    test('creates ultra 4K preset with correct values', () {
      final config = VideoQualityConfig.fromPreset(VideoQualityPreset.ultra4K);

      expect(config.bitrate, equals(45000000)); // 45 Mbps
      expect(config.resolution, equals(const Size(3840, 2160)));
      expect(config.preset, equals(VideoQualityPreset.ultra4K));
    });

    test('creates 1080p high preset with correct values', () {
      final config = VideoQualityConfig.fromPreset(
        VideoQualityPreset.p1080High,
      );

      expect(config.bitrate, equals(16000000)); // 16 Mbps
      expect(config.resolution, equals(const Size(1920, 1080)));
      expect(config.preset, equals(VideoQualityPreset.p1080High));
    });

    test('creates 1080p preset with correct values', () {
      final config = VideoQualityConfig.fromPreset(VideoQualityPreset.p1080);

      expect(config.bitrate, equals(8000000)); // 8 Mbps
      expect(config.resolution, equals(const Size(1920, 1080)));
      expect(config.preset, equals(VideoQualityPreset.p1080));
    });

    test('creates 720p high preset with correct values', () {
      final config = VideoQualityConfig.fromPreset(VideoQualityPreset.p720High);

      expect(config.bitrate, equals(5000000)); // 5 Mbps
      expect(config.resolution, equals(const Size(1280, 720)));
      expect(config.preset, equals(VideoQualityPreset.p720High));
    });

    test('creates 720p preset with correct values', () {
      final config = VideoQualityConfig.fromPreset(VideoQualityPreset.p720);

      expect(config.bitrate, equals(3000000)); // 3 Mbps
      expect(config.resolution, equals(const Size(1280, 720)));
      expect(config.preset, equals(VideoQualityPreset.p720));
    });

    test('creates 480p preset with correct values', () {
      final config = VideoQualityConfig.fromPreset(VideoQualityPreset.p480);

      expect(config.bitrate, equals(2500000)); // 2.5 Mbps
      expect(config.resolution, equals(const Size(854, 480)));
      expect(config.preset, equals(VideoQualityPreset.p480));
    });

    test('creates low quality preset with correct values', () {
      final config = VideoQualityConfig.fromPreset(VideoQualityPreset.low);

      expect(config.bitrate, equals(1000000)); // 1 Mbps
      expect(config.resolution, equals(const Size(640, 360)));
      expect(config.preset, equals(VideoQualityPreset.low));
    });

    test('creates custom preset with default values', () {
      final config = VideoQualityConfig.fromPreset(VideoQualityPreset.custom);

      expect(config.bitrate, equals(8000000)); // Default 8 Mbps
      expect(config.resolution, isNull);
      expect(config.preset, equals(VideoQualityPreset.custom));
    });

    test('creates custom configuration with specific values', () {
      final config = VideoQualityConfig.custom(
        bitrate: 10000000,
        resolution: const Size(1920, 1080),
      );

      expect(config.bitrate, equals(10000000));
      expect(config.resolution, equals(const Size(1920, 1080)));
      expect(config.preset, equals(VideoQualityPreset.custom));
    });

    test('copyWith creates modified copy', () {
      final original = VideoQualityConfig.fromPreset(VideoQualityPreset.p1080);
      final modified = original.copyWith(bitrate: 12000000);

      expect(modified.bitrate, equals(12000000));
      expect(modified.resolution, equals(original.resolution));
      expect(modified.preset, equals(original.preset));
    });

    test('toString returns formatted string', () {
      final config = VideoQualityConfig.fromPreset(VideoQualityPreset.p1080);
      final string = config.toString();

      expect(string, contains('VideoQualityConfig'));
      expect(string, contains('1080'));
      expect(string, contains('8Mbps'));
      expect(string, contains('1920x1080'));
    });

    test('equality operator works correctly', () {
      final config1 = VideoQualityConfig.fromPreset(VideoQualityPreset.p1080);
      final config2 = VideoQualityConfig.fromPreset(VideoQualityPreset.p1080);
      final config3 = VideoQualityConfig.fromPreset(VideoQualityPreset.p720);

      expect(config1, equals(config2));
      expect(config1, isNot(equals(config3)));
    });

    test('hashCode is consistent', () {
      final config1 = VideoQualityConfig.fromPreset(VideoQualityPreset.p1080);
      final config2 = VideoQualityConfig.fromPreset(VideoQualityPreset.p1080);

      expect(config1.hashCode, equals(config2.hashCode));
    });

    group('toMap / fromMap', () {
      test('roundtrip with resolution', () {
        final config = VideoQualityConfig.fromPreset(VideoQualityPreset.p1080);
        final map = config.toMap();
        final restored = VideoQualityConfig.fromMap(map);

        expect(restored.bitrate, config.bitrate);
        expect(restored.resolution, config.resolution);
        expect(restored.preset, config.preset);
      });

      test('roundtrip without resolution (custom)', () {
        final config = VideoQualityConfig.fromPreset(VideoQualityPreset.custom);
        final map = config.toMap();
        final restored = VideoQualityConfig.fromMap(map);

        expect(restored.bitrate, config.bitrate);
        expect(restored.resolution, isNull);
        expect(restored.preset, VideoQualityPreset.custom);
      });

      test('fromMap parses string values via safe parsers', () {
        final map = <String, dynamic>{
          'bitrate': '5000000',
          'width': '1280',
          'height': '720',
          'preset': 'p720',
        };
        final restored = VideoQualityConfig.fromMap(map);

        expect(restored.bitrate, 5000000);
        expect(restored.resolution, equals(const Size(1280, 720)));
        expect(restored.preset, VideoQualityPreset.p720);
      });

      test('toMap contains expected keys', () {
        final config = VideoQualityConfig.fromPreset(VideoQualityPreset.p720);
        final map = config.toMap();

        expect(map['bitrate'], config.bitrate);
        expect(map['width'], 1280.0);
        expect(map['height'], 720.0);
        expect(map['preset'], 'p720');
      });
    });
  });
}
