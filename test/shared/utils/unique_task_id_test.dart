import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor/shared/utils/unique_task_id.dart';

void main() {
  group('uniqueTaskId', () {
    test('never repeats, however fast it is called', () {
      final ids = [for (var i = 0; i < 10000; i++) uniqueTaskId()];

      expect(ids.toSet(), hasLength(ids.length));
      for (var i = 1; i < ids.length; i++) {
        expect(int.parse(ids[i]), greaterThan(int.parse(ids[i - 1])));
      }
    });

    test('gives configs built in one go their own task ids', () {
      final video = EditorVideo.file('/voice.m4a');
      final ids = [
        for (var i = 0; i < 100; i++) WaveformConfigs(video: video).id,
        for (var i = 0; i < 100; i++) AudioExtractConfigs(video: video).id,
      ];

      expect(ids.toSet(), hasLength(ids.length));
    });
  });
}
