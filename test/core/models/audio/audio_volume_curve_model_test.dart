import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('AudioVolumeCurve', () {
    final curve = AudioVolumeCurve(const [
      AudioVolumePoint(time: Duration(seconds: 1), volume: 1),
      AudioVolumePoint(time: Duration(seconds: 2), volume: 0.2),
      AudioVolumePoint(time: Duration(seconds: 3), volume: 0.2),
      AudioVolumePoint(time: Duration(seconds: 3), volume: 0.6),
    ]);

    group('volumeAt', () {
      test('holds the first and the last volume outside the points', () {
        expect(curve.volumeAt(Duration.zero), 1);
        expect(curve.volumeAt(const Duration(seconds: 9)), 0.6);
      });

      test('moves in a straight line between two points', () {
        expect(
          curve.volumeAt(const Duration(milliseconds: 1500)),
          closeTo(0.6, 1e-9),
        );
        expect(
          curve.volumeAt(const Duration(milliseconds: 2500)),
          closeTo(0.2, 1e-9),
        );
      });

      test('jumps where two points share a time', () {
        expect(
          curve.volumeAt(const Duration(microseconds: 2999999)),
          closeTo(0.2, 1e-6),
        );
        expect(curve.volumeAt(const Duration(seconds: 3)), 0.6);
      });

      test('is 1 without points', () {
        expect(AudioVolumeCurve(const []).volumeAt(Duration.zero), 1);
      });
    });

    test('survives a map round trip', () {
      expect(AudioVolumeCurve.fromMap(curve.toMap()), curve);
    });

    test('sends interleaved microseconds and volumes to native', () {
      expect(curve.toChannelData(), [
        1e6, 1, 2e6, 0.2, 3e6, 0.2, 3e6, 0.6, //
      ]);
    });

    test('sorts its points, keeping the order of a shared time', () {
      final unsorted = AudioVolumeCurve(const [
        AudioVolumePoint(time: Duration(seconds: 3), volume: 0.2),
        AudioVolumePoint(time: Duration(seconds: 3), volume: 0.6),
        AudioVolumePoint(time: Duration(seconds: 2), volume: 0.2),
        AudioVolumePoint(time: Duration(seconds: 1), volume: 1),
      ]);
      expect(unsorted, curve);
    });
  });

  group('VideoAudioTrack.volumeCurve', () {
    final track = VideoAudioTrack(
      path: '/music.mp3',
      volumeCurve: AudioVolumeCurve(const [
        AudioVolumePoint(time: Duration.zero, volume: 1),
        AudioVolumePoint(time: Duration(seconds: 1), volume: 0.3),
      ]),
    );

    test('survives JSON and takes part in equality', () {
      final restored = VideoAudioTrack.fromJson(track.toJson());
      expect(restored, track);
      expect(restored.hashCode, track.hashCode);
      expect(
        track,
        isNot(track.copyWith(volumeCurve: AudioVolumeCurve(const []))),
      );
    });

    test(
      'reaches the native renderers only when it changes something',
      () async {
        Future<List<dynamic>> channelTracks(VideoAudioTrack t) async {
          final map = await VideoRenderData(
            videoSegments: [VideoSegment(video: EditorVideo.file('/a.mp4'))],
            audioTracks: [t],
          ).toAsyncMap();
          return map['audioTracks'] as List<dynamic>;
        }

        final sent = (await channelTracks(track)).single as Map;
        expect(sent['volumeCurve'], [0, 1, 1e6, 0.3]);

        final flat = track.copyWith(
          volumeCurve: AudioVolumeCurve(const [
            AudioVolumePoint(time: Duration.zero, volume: 1),
          ]),
        );
        expect(
          ((await channelTracks(flat)).single as Map).containsKey(
            'volumeCurve',
          ),
          isFalse,
        );
      },
    );
  });
}
