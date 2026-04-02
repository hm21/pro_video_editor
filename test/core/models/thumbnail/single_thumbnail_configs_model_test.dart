import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('SingleThumbnailConfigs', () {
    final video = EditorVideo.asset('assets/test.mp4');

    test('creates with required parameters', () {
      final config = SingleThumbnailConfigs(
        video: video,
        outputSize: const Size(100, 100),
        position: ThumbnailPosition.first,
      );

      expect(config.position, ThumbnailPosition.first);
      expect(config.videoDuration, isNull);
      expect(config.outputSize, const Size(100, 100));
      expect(config.outputFormat, ThumbnailFormat.jpeg);
      expect(config.boxFit, ThumbnailBoxFit.cover);
      expect(config.jpegQuality, 90);
      expect(config.id, isNotEmpty);
    });

    test('creates with all optional parameters', () {
      final config = SingleThumbnailConfigs(
        video: video,
        outputSize: const Size(200, 150),
        position: ThumbnailPosition.last,
        videoDuration: const Duration(seconds: 30),
        outputFormat: ThumbnailFormat.png,
        boxFit: ThumbnailBoxFit.contain,
        jpegQuality: 80,
        id: 'custom-id',
      );

      expect(config.position, ThumbnailPosition.last);
      expect(config.videoDuration, const Duration(seconds: 30));
      expect(config.outputSize, const Size(200, 150));
      expect(config.outputFormat, ThumbnailFormat.png);
      expect(config.boxFit, ThumbnailBoxFit.contain);
      expect(config.jpegQuality, 80);
      expect(config.id, 'custom-id');
    });

    test('toMap serializes correctly', () {
      final config = SingleThumbnailConfigs(
        video: video,
        outputSize: const Size(256, 128),
        position: ThumbnailPosition.first,
        id: 'test-id',
        jpegQuality: 75,
        outputFormat: ThumbnailFormat.png,
        boxFit: ThumbnailBoxFit.contain,
      );

      final map = config.toMap();

      expect(map['id'], 'test-id');
      expect(map['jpegQuality'], 75);
      expect(map['boxFit'], 'contain');
      expect(map['outputFormat'], 'png');
      expect(map['outputWidth'], 256);
      expect(map['outputHeight'], 128);
      expect(map['timestamps'], isEmpty);
    });
  });

  group('ThumbnailPosition', () {
    test('has correct values', () {
      expect(ThumbnailPosition.values.length, 2);
      expect(ThumbnailPosition.values, contains(ThumbnailPosition.first));
      expect(ThumbnailPosition.values, contains(ThumbnailPosition.last));
    });
  });
}
