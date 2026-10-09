import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  const bass = AudioEqualizerBand(
    type: AudioEqualizerBandType.lowShelf,
    frequency: 150,
    gain: 6,
  );
  const presence = AudioEqualizerBand(
    type: AudioEqualizerBandType.peak,
    frequency: 2500,
    gain: -3,
    q: 1.4,
  );
  const treble = AudioEqualizerBand(
    type: AudioEqualizerBandType.highShelf,
    frequency: 4000,
  );

  group('AudioEqualizerBand', () {
    test('defaults to no gain and a Q of 1/√2', () {
      const band = AudioEqualizerBand(
        type: AudioEqualizerBandType.peak,
        frequency: 1000,
      );

      expect(band.gain, 0);
      expect(band.q, closeTo(1 / math.sqrt(2), 1e-15));
    });

    test('toMap sends the fields the native side reads', () {
      expect(presence.toMap(), {
        'type': 'peak',
        'frequencyHz': 2500.0,
        'gainDb': -3.0,
        'q': 1.4,
      });
    });

    test('fromMap round-trips toMap for every type', () {
      for (final band in [bass, presence, treble]) {
        expect(AudioEqualizerBand.fromMap(band.toMap()), band);
      }
    });

    test('fromMap falls back to no gain and the default Q', () {
      expect(
        AudioEqualizerBand.fromMap(const {
          'type': 'peak',
          'frequencyHz': 1000,
          'q': 0,
        }),
        const AudioEqualizerBand(
          type: AudioEqualizerBandType.peak,
          frequency: 1000,
        ),
      );
    });

    test('fromMap rejects an unknown type or a frequency of 0 or less', () {
      expect(
        () => AudioEqualizerBand.fromMap(const {
          'type': 'notch',
          'frequencyHz': 1000,
        }),
        throwsFormatException,
      );
      expect(
        () => AudioEqualizerBand.fromMap(const {
          'type': 'peak',
          'frequencyHz': 0,
        }),
        throwsFormatException,
      );
      expect(
        () => AudioEqualizerBand.fromMap(const {'type': 'lowShelf'}),
        throwsFormatException,
      );
    });

    test('copyWith replaces only the given fields', () {
      expect(
        presence.copyWith(gain: 4),
        const AudioEqualizerBand(
          type: AudioEqualizerBandType.peak,
          frequency: 2500,
          gain: 4,
          q: 1.4,
        ),
      );
      expect(presence.copyWith(), presence);
    });

    test('equal settings are equal and hash alike', () {
      const same = AudioEqualizerBand(
        type: AudioEqualizerBandType.peak,
        frequency: 2500,
        gain: -3,
        q: 1.4,
      );

      expect(same, presence);
      expect(same.hashCode, presence.hashCode);
      expect(presence.copyWith(q: 2), isNot(presence));
      expect(
        presence.copyWith(type: AudioEqualizerBandType.highShelf),
        isNot(presence),
      );
    });

    test('toString names the class and its type', () {
      expect(
        presence.toString(),
        startsWith('AudioEqualizerBand(type: peak, frequency: 2500.0'),
      );
    });
  });

  group('AudioEqualizer', () {
    const equalizer = AudioEqualizer(bands: [bass, presence, treble]);

    test('is flat without bands or while every band has no gain', () {
      expect(const AudioEqualizer().isFlat, isTrue);
      expect(const AudioEqualizer(bands: [treble]).isFlat, isTrue);
      expect(equalizer.isFlat, isFalse);
      expect(const AudioEqualizer(bands: [presence]).isFlat, isFalse);
    });

    test('boosts only while a band raises the audio', () {
      expect(equalizer.boosts, isTrue);
      expect(const AudioEqualizer(bands: [presence, treble]).boosts, isFalse);
      expect(const AudioEqualizer().boosts, isFalse);
    });

    test('toMap sends the bands in order', () {
      expect(equalizer.toMap(), {
        'bands': [bass.toMap(), presence.toMap(), treble.toMap()],
      });
    });

    test('fromMap round-trips toMap', () {
      expect(AudioEqualizer.fromMap(equalizer.toMap()), equalizer);
    });

    test('fromMap skips the bands it cannot parse', () {
      final parsed = AudioEqualizer.fromMap({
        'bands': [
          bass.toMap(),
          const {'type': 'notch', 'frequencyHz': 1000, 'gainDb': 3},
          const {'type': 'peak', 'frequencyHz': -50, 'gainDb': 3},
          'not a band',
          treble.toMap(),
        ],
      });

      expect(parsed, const AudioEqualizer(bands: [bass, treble]));
    });

    test('fromMap without bands gives a flat equalizer', () {
      expect(AudioEqualizer.fromMap(const {}), const AudioEqualizer());
    });

    test('copyWith replaces the bands', () {
      expect(
        equalizer.copyWith(bands: [treble]),
        const AudioEqualizer(bands: [treble]),
      );
      expect(equalizer.copyWith(), equalizer);
    });

    test('equal bands are equal and hash alike, in order', () {
      final same = AudioEqualizer(bands: [...equalizer.bands]);

      expect(same, equalizer);
      expect(same.hashCode, equalizer.hashCode);
      expect(
        const AudioEqualizer(bands: [presence, bass, treble]),
        isNot(equalizer),
      );
    });

    test('toString lists the bands', () {
      expect(
        equalizer.toString(),
        startsWith('AudioEqualizer(bands: [AudioEqualizerBand(type: lowShelf'),
      );
    });
  });
}
