import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '/core/analysis/audio_level_envelope.dart';
import '/core/models/audio/audio_track_model.dart';
import '/core/models/audio/audio_volume_curve_model.dart';
import '/shared/utils/parser/double_parser.dart';
import '/shared/utils/parser/int_parser.dart';

/// Lowers a track while someone talks on other tracks, and brings it back
/// up when they stop: the classic ducking of music under a voice-over.
///
/// The voices are measured by their loudness alone, with no speech
/// recognition, so any sound louder than [threshold] counts as talking.
/// [curve] turns their [AudioLevelEnvelope] into the [AudioVolumeCurve] the
/// ducked track follows; set it on [VideoAudioTrack.volumeCurve] for the
/// render, and scale a preview by [AudioVolumeCurve.volumeAt] to hear the
/// same dips. [analyze] does both steps for a list of voice tracks.
///
/// The dip is planned with the whole voice known in advance, so the track
/// is already down when the first word starts.
@immutable
class AudioDucking {
  /// Creates a ducking that lowers a track to [volume] while someone talks.
  const AudioDucking({
    this.volume = 0.25,
    this.attack = const Duration(milliseconds: 250),
    this.release = const Duration(milliseconds: 500),
    this.hold = const Duration(milliseconds: 400),
    this.threshold = 0.02,
  }) : assert(volume >= 0 && volume <= 1, '[volume] must be between 0 and 1'),
       assert(threshold > 0, '[threshold] must be greater than 0');

  /// Creates a ducking from a map written by [toMap].
  factory AudioDucking.fromMap(Map<String, dynamic> map) {
    const defaults = AudioDucking();
    Duration duration(String key, Duration fallback) => map[key] == null
        ? fallback
        : Duration(microseconds: safeParseInt(map[key]));
    return AudioDucking(
      volume: safeParseDouble(map['volume'], fallback: defaults.volume),
      attack: duration('attack', defaults.attack),
      release: duration('release', defaults.release),
      hold: duration('hold', defaults.hold),
      threshold: safeParseDouble(
        map['threshold'],
        fallback: defaults.threshold,
      ),
    );
  }

  /// How loud the track stays while someone talks, as a multiplier of its
  /// own volume: 0 silences it, 1 leaves it unchanged.
  ///
  /// **Default**: `0.25` (about 12 dB quieter)
  final double volume;

  /// How long the track takes to go down. The fall ends where the talking
  /// starts.
  ///
  /// **Default**: 250 ms
  final Duration attack;

  /// How long the track takes to come back up once the talking has stopped
  /// for [hold].
  ///
  /// **Default**: 500 ms
  final Duration release;

  /// How long the talking has to stop before the track comes back up, so
  /// the pauses between words and short sentences stay quiet.
  ///
  /// **Default**: 400 ms
  final Duration hold;

  /// How loud a voice has to be to count as talking, as a peak level from 0
  /// to 1 of the voice as it plays on the exported video (after its volume,
  /// fades and volume curve).
  ///
  /// **Default**: `0.02` (about -34 dBFS), above the background noise of a
  /// typical phone recording and below quiet speech.
  final double threshold;

  /// Talking shorter than this, like a click or a tap on the microphone,
  /// does not lower the track, and a quieter stretch shorter than this does
  /// not interrupt talking.
  static const Duration minimumTalk = Duration(milliseconds: 50);

  /// Measures [voices] and returns the curve a track follows to duck under
  /// them.
  ///
  /// [videoDuration] is the length of the exported video; it is needed only
  /// when a voice loops without an `endTime`. See
  /// [AudioLevelEnvelope.ofTracks] for how the voices are measured.
  Future<AudioVolumeCurve> analyze(
    List<VideoAudioTrack> voices, {
    Duration? videoDuration,
  }) async {
    if (volume == 1 || voices.isEmpty) return AudioVolumeCurve(const []);
    final envelope = await AudioLevelEnvelope.ofTracks(
      voices,
      videoDuration: videoDuration,
    );
    return curve(envelope);
  }

  /// The curve a track follows to duck under the talking in [voices].
  ///
  /// The curve starts at 0, rests at 1 wherever nobody talks and has no
  /// points at all when nobody does.
  AudioVolumeCurve curve(AudioLevelEnvelope voices) {
    if (volume == 1) return AudioVolumeCurve(const []);
    final ranges = _talkRanges(voices);
    if (ranges.isEmpty) return AudioVolumeCurve(const []);

    // Zero-length ramps would make two points share a time; a millisecond
    // is as good as a jump to the ear.
    final attackUs = math.max(attack.inMicroseconds, 1000);
    final releaseUs = math.max(release.inMicroseconds, 1000);
    final holdUs = math.max(hold.inMicroseconds, 0);

    final points = <(int, double)>[];
    int? riseStart;
    int? riseEnd;
    for (final (start, end) in ranges) {
      final fallStart = start - attackUs;
      if (riseStart == null || riseEnd == null) {
        points
          ..add((fallStart, 1))
          ..add((start, volume));
      } else if (fallStart >= riseEnd) {
        points
          ..add((riseStart, volume))
          ..add((riseEnd, 1));
        if (fallStart > riseEnd) points.add((fallStart, 1));
        points.add((start, volume));
      } else {
        // The next fall starts before the track is back up: it turns down
        // where the rise and the fall cross.
        final cross =
            (attackUs * releaseUs +
                riseStart * attackUs +
                fallStart * releaseUs) /
            (attackUs + releaseUs);
        final crossVolume =
            volume + (1 - volume) * (cross - riseStart) / releaseUs;
        points
          ..add((riseStart, volume))
          ..add((cross.round(), crossVolume.clamp(volume, 1)))
          ..add((start, volume));
      }
      riseStart = end + holdUs;
      riseEnd = riseStart + releaseUs;
    }
    points
      ..add((riseStart!, volume))
      ..add((riseEnd!, 1));

    return AudioVolumeCurve(_fromZero(points));
  }

  /// The ranges, in µs on the exported video, where [voices] talk, with
  /// blips shorter than [minimumTalk] dropped and pauses up to [hold]
  /// bridged.
  ///
  /// Blips are dropped first, so a click just before a sentence does not
  /// start the dip early. Dips shorter than [minimumTalk] are bridged before
  /// that, so a word that flickers around [threshold] is not taken apart
  /// into blips.
  List<(int, int)> _talkRanges(AudioLevelEnvelope voices) {
    final levels = voices.levels;
    final stepUs = 1e6 / voices.levelsPerSecond;
    final minimumUs = minimumTalk.inMicroseconds;
    final holdUs = math.max(hold.inMicroseconds, 0);

    final loud = <(int, int)>[];
    int? start;
    for (var i = 0; i <= levels.length; i++) {
      final talking = i < levels.length && levels[i] >= threshold;
      if (talking && start == null) {
        start = i;
      } else if (!talking && start != null) {
        final from = (start * stepUs).round();
        final to = (i * stepUs).round();
        if (loud.isNotEmpty && from - loud.last.$2 < minimumUs) {
          loud.last = (loud.last.$1, to);
        } else {
          loud.add((from, to));
        }
        start = null;
      }
    }

    final ranges = <(int, int)>[];
    for (final (from, to) in loud) {
      if (to - from < minimumUs) continue;
      if (ranges.isNotEmpty && from - ranges.last.$2 <= holdUs) {
        ranges.last = (ranges.last.$1, to);
      } else {
        ranges.add((from, to));
      }
    }
    return ranges;
  }

  /// [points] cut at the start of the video: a fall that would begin before
  /// it starts there, part of the way down.
  static List<AudioVolumePoint> _fromZero(List<(int, double)> points) {
    var first = 0;
    while (first < points.length && points[first].$1 < 0) {
      first++;
    }
    final result = <AudioVolumePoint>[];
    if (first > 0 && first < points.length) {
      final (beforeTime, beforeVolume) = points[first - 1];
      final (afterTime, afterVolume) = points[first];
      final t = -beforeTime / (afterTime - beforeTime);
      if (afterTime > 0) {
        result.add(
          AudioVolumePoint(
            time: Duration.zero,
            volume: beforeVolume + (afterVolume - beforeVolume) * t,
          ),
        );
      }
    }
    for (var i = first; i < points.length; i++) {
      result.add(
        AudioVolumePoint(
          time: Duration(microseconds: points[i].$1),
          volume: points[i].$2,
        ),
      );
    }
    return result;
  }

  /// Returns a copy with the given fields replaced.
  AudioDucking copyWith({
    double? volume,
    Duration? attack,
    Duration? release,
    Duration? hold,
    double? threshold,
  }) {
    return AudioDucking(
      volume: volume ?? this.volume,
      attack: attack ?? this.attack,
      release: release ?? this.release,
      hold: hold ?? this.hold,
      threshold: threshold ?? this.threshold,
    );
  }

  /// Converts the ducking into a map.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'volume': volume,
    'attack': attack.inMicroseconds,
    'release': release.inMicroseconds,
    'hold': hold.inMicroseconds,
    'threshold': threshold,
  };

  @override
  bool operator ==(Object other) =>
      other is AudioDucking &&
      other.volume == volume &&
      other.attack == attack &&
      other.release == release &&
      other.hold == hold &&
      other.threshold == threshold;

  @override
  int get hashCode => Object.hash(volume, attack, release, hold, threshold);

  @override
  String toString() =>
      'AudioDucking(volume: $volume, attack: $attack, release: $release, '
      'hold: $hold, threshold: $threshold)';
}
