import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// An envelope at 100 levels a second that is loud over [talkMs] ranges.
AudioLevelEnvelope _talking(List<(int, int)> talkMs, {int lengthMs = 10000}) {
  final levels = Float32List(lengthMs ~/ 10);
  for (final (from, to) in talkMs) {
    for (var i = from ~/ 10; i < to ~/ 10; i++) {
      levels[i] = 0.5;
    }
  }
  return AudioLevelEnvelope(levels, levelsPerSecond: 100);
}

List<(int, double)> _points(AudioVolumeCurve curve) => [
  for (final p in curve.points) (p.time.inMilliseconds, p.volume),
];

void main() {
  group('AudioDucking', () {
    const ducking = AudioDucking(
      volume: 0.2,
      attack: Duration(milliseconds: 200),
      release: Duration(milliseconds: 400),
      hold: Duration(milliseconds: 300),
    );

    group('curve', () {
      test(
        'is down while someone talks and back up after hold and release',
        () {
          final curve = ducking.curve(_talking([(1000, 2000)]));
          expect(_points(curve), [
            (800, 1.0),
            (1000, 0.2),
            (2300, 0.2),
            (2700, 1.0),
          ]);
          expect(curve.volumeAt(const Duration(milliseconds: 1500)), 0.2);
          expect(curve.volumeAt(const Duration(milliseconds: 5000)), 1);
        },
      );

      test('stays down through a pause no longer than hold', () {
        final curve = ducking.curve(_talking([(1000, 2000), (2300, 3000)]));
        expect(_points(curve), [
          (800, 1.0),
          (1000, 0.2),
          (3300, 0.2),
          (3700, 1.0),
        ]);
      });

      test('turns back down where an unfinished rise meets the next fall', () {
        // Up from 2300 ms to 2700 ms, down again from 2500 ms to 2700 ms.
        final curve = ducking.curve(_talking([(1000, 2000), (2700, 3500)]));
        final points = _points(curve);
        expect(points.sublist(0, 3), [(800, 1.0), (1000, 0.2), (2300, 0.2)]);
        final (crossMs, crossVolume) = points[3];
        expect(crossMs, closeTo(2567, 1));
        expect(crossVolume, closeTo(0.2 + 0.8 * 267 / 400, 0.01));
        expect(points.sublist(4), [(2700, 0.2), (3800, 0.2), (4200, 1.0)]);
        // Never above either ramp, so the dip is the lower of the two.
        expect(curve.volumeAt(Duration(milliseconds: crossMs)), lessThan(0.8));
      });

      test('is already part of the way down when talking starts the video', () {
        final curve = ducking.curve(_talking([(100, 1000)]));
        expect(curve.points.first.time, Duration.zero);
        expect(curve.points.first.volume, closeTo(0.6, 1e-9));
      });

      test('ignores blips and anything below the threshold', () {
        expect(ducking.curve(_talking([(1000, 1030)])).points, isEmpty);

        final quiet = Float32List(1000)..fillRange(100, 300, 0.01);
        expect(
          ducking.curve(AudioLevelEnvelope(quiet, levelsPerSecond: 100)).points,
          isEmpty,
        );
      });

      test('does not start or keep the dip for a blip near talking', () {
        // A click 200 ms before and one 200 ms after, both within hold.
        final curve = ducking.curve(
          _talking([(800, 820), (1000, 2000), (2200, 2220)]),
        );
        expect(_points(curve), [
          (800, 1.0),
          (1000, 0.2),
          (2300, 0.2),
          (2700, 1.0),
        ]);
      });

      test('keeps a word whose level flickers below the threshold', () {
        // Loud in 30 ms pieces with 20 ms gaps: no piece is long enough on
        // its own, the word is.
        final curve = ducking.curve(
          _talking([(1000, 1030), (1050, 1080), (1100, 1130)]),
        );
        expect(_points(curve), [
          (800, 1.0),
          (1000, 0.2),
          (1430, 0.2),
          (1830, 1.0),
        ]);
      });

      test('has no points when it would not lower anything', () {
        final envelope = _talking([(1000, 2000)]);
        expect(ducking.copyWith(volume: 1).curve(envelope).points, isEmpty);
      });
    });

    test('survives a map round trip', () {
      expect(AudioDucking.fromMap(ducking.toMap()), ducking);
      expect(AudioDucking.fromMap(const {}), const AudioDucking());
    });
  });

  group('AudioLevelEnvelope.fromWaveforms', () {
    /// A 4 s mono waveform at 100 peaks a second, loud only in its second
    /// second.
    final waveform = WaveformData(
      leftChannel: Float32List(400)..fillRange(100, 200, 0.5),
      sampleRate: 44100,
      duration: const Duration(seconds: 4),
      samplesPerSecond: 100,
    );

    /// Where the envelope is loud, in ms.
    List<(int, int)> loud(AudioLevelEnvelope envelope) {
      final ranges = <(int, int)>[];
      int? start;
      final stepMs = 1000 ~/ envelope.levelsPerSecond;
      for (var i = 0; i <= envelope.levels.length; i++) {
        final on = i < envelope.levels.length && envelope.levels[i] > 0;
        if (on && start == null) start = i;
        if (!on && start != null) {
          ranges.add((start * stepMs, i * stepMs));
          start = null;
        }
      }
      return ranges;
    }

    AudioLevelEnvelope place(VideoAudioTrack track, {Duration? video}) =>
        AudioLevelEnvelope.fromWaveforms(
          [track],
          [waveform],
          videoDuration: video,
          levelsPerSecond: 100,
        );

    test('places a track at its start time, trimmed to its window', () {
      final envelope = place(
        const VideoAudioTrack(
          path: '/voice.m4a',
          startTime: Duration(seconds: 2),
          audioStartTime: Duration(milliseconds: 500),
        ),
      );
      expect(loud(envelope), [(2500, 3500)]);
      expect(envelope.duration, const Duration(milliseconds: 5500));
    });

    test('follows the playback speed', () {
      final envelope = place(
        const VideoAudioTrack(path: '/voice.m4a', playbackSpeed: 2),
      );
      expect(loud(envelope), [(500, 1000)]);
    });

    test('repeats a looping track until its end', () {
      final envelope = place(
        const VideoAudioTrack(
          path: '/voice.m4a',
          loop: true,
          audioEndTime: Duration(seconds: 2),
          endTime: Duration(seconds: 5),
        ),
      );
      expect(loud(envelope), [(1000, 2000), (3000, 4000)]);
    });

    test('scales the level by volume and fades', () {
      final envelope = place(
        const VideoAudioTrack(
          path: '/voice.m4a',
          volume: 0.5,
          fadeInDuration: Duration(seconds: 2),
        ),
      );
      // 0.5 peak × 0.5 volume × 1005 / 2000 into the fade.
      expect(
        envelope.levelAt(const Duration(milliseconds: 1005)),
        closeTo(0.1256, 0.0001),
      );
      expect(
        envelope.levelAt(const Duration(milliseconds: 1995)),
        closeTo(0.25, 0.01),
      );
    });

    test('follows the track\'s own volume curve', () {
      final envelope = place(
        VideoAudioTrack(
          path: '/voice.m4a',
          volumeCurve: AudioVolumeCurve(const [
            AudioVolumePoint(time: Duration(milliseconds: 1500), volume: 1),
            AudioVolumePoint(time: Duration(milliseconds: 1500), volume: 0),
          ]),
        ),
      );
      expect(loud(envelope), [(1000, 1500)]);
    });

    test('stops at the end of the video', () {
      final envelope = place(
        const VideoAudioTrack(path: '/voice.m4a', loop: true),
        video: const Duration(milliseconds: 1500),
      );
      expect(loud(envelope), [(1000, 1500)]);
    });

    test('needs a video duration for a loop without an end', () {
      expect(
        () => place(const VideoAudioTrack(path: '/voice.m4a', loop: true)),
        throwsArgumentError,
      );
    });
  });
}
