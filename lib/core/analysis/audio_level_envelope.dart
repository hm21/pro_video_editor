import 'dart:math' as math;
import 'dart:typed_data';

import '../models/audio/audio_track_model.dart';
import '../models/audio/waveform_configs_model.dart';
import '../models/audio/waveform_data_model.dart';
import '../models/video/editor_video_model.dart';
import '../platform/platform_interface.dart';

/// How loud a set of audio tracks is over the exported video: the highest
/// peak level among them, [levelsPerSecond] times a second from its start.
///
/// Each track is placed the way the render places it: at its
/// `startTime`, trimmed to its source window, sped up or slowed down,
/// looped, faded and scaled by its volume and `volumeCurve`. Its equalizer
/// is left out.
///
/// [AudioDucking.curve] reads an envelope of the voice-over tracks to find
/// where somebody talks.
class AudioLevelEnvelope {
  /// Creates an envelope from [levels] that start at the video's first frame.
  AudioLevelEnvelope(
    this.levels, {
    this.levelsPerSecond = defaultLevelsPerSecond,
  }) : assert(levelsPerSecond > 0, '[levelsPerSecond] must be positive');

  /// Places [tracks] on the exported video from their [waveforms], given in
  /// the same order.
  ///
  /// Each waveform has to start at the beginning of its track's file and
  /// cover at least the track's source window. [videoDuration] cuts off the
  /// tracks that play past the end of the video and is required for a track
  /// that loops without an `endTime`.
  ///
  /// Throws an [ArgumentError] when the lists differ in length or a looping
  /// track has no end.
  factory AudioLevelEnvelope.fromWaveforms(
    List<VideoAudioTrack> tracks,
    List<WaveformData> waveforms, {
    Duration? videoDuration,
    int levelsPerSecond = defaultLevelsPerSecond,
  }) {
    if (tracks.length != waveforms.length) {
      throw ArgumentError('Every track needs a waveform');
    }
    final placements = <_Placement>[
      for (var i = 0; i < tracks.length; i++)
        ?_Placement.of(tracks[i], waveforms[i], videoDuration),
    ];
    final endUs = placements.fold<int>(0, (end, p) => math.max(end, p.endUs));
    final levels = Float32List((endUs * levelsPerSecond / 1e6).ceil());
    for (final placement in placements) {
      placement.addTo(levels, levelsPerSecond);
    }
    return AudioLevelEnvelope(levels, levelsPerSecond: levelsPerSecond);
  }

  /// Measures [tracks] with `ProVideoEditor.getWaveform` and places them on
  /// the exported video; see [AudioLevelEnvelope.fromWaveforms].
  ///
  /// Each file is decoded once, from its start to the end of its source
  /// window, so keep the tracks to short sounds like voice-overs.
  ///
  /// Throws what `getWaveform` throws for a file without audio or one that
  /// cannot be decoded.
  static Future<AudioLevelEnvelope> ofTracks(
    List<VideoAudioTrack> tracks, {
    Duration? videoDuration,
    int levelsPerSecond = defaultLevelsPerSecond,
  }) async {
    final requests = <String, Future<WaveformData>>{};
    Future<WaveformData> waveformOf(VideoAudioTrack track) {
      final end = track.audioEndTime;
      return requests.putIfAbsent(
        '${track.path}|${end?.inMicroseconds}',
        () => ProVideoEditor.instance.getWaveform(
          WaveformConfigs(
            video: track.path.startsWith('content://')
                ? EditorVideo.content(track.path)
                : EditorVideo.file(track.path),
            resolution: WaveformResolution.high,
            endTime: end,
          ),
        ),
      );
    }

    final waveforms = await Future.wait(tracks.map(waveformOf));
    return AudioLevelEnvelope.fromWaveforms(
      tracks,
      waveforms,
      videoDuration: videoDuration,
      levelsPerSecond: levelsPerSecond,
    );
  }

  /// The resolution [AudioLevelEnvelope.ofTracks] measures at: 5 ms steps.
  static const int defaultLevelsPerSecond = 200;

  /// The peak level, from 0 up, of every step from the video's first frame.
  ///
  /// A level can pass 1 where a track's volume amplifies it.
  final Float32List levels;

  /// How many [levels] there are a second.
  final int levelsPerSecond;

  /// How long the envelope runs: up to where the last track stops sounding.
  Duration get duration =>
      Duration(microseconds: (levels.length * 1e6 / levelsPerSecond).round());

  /// The level at [time]: 0 before the start and after the end.
  double levelAt(Duration time) {
    final index = (time.inMicroseconds * levelsPerSecond / 1e6).floor();
    if (index < 0 || index >= levels.length) return 0;
    return levels[index];
  }
}

/// Where one track sounds on the exported video and how loud its source is.
class _Placement {
  _Placement._({
    required this.track,
    required this.peaks,
    required this.peaksPerSecond,
    required this.sourceStartUs,
    required this.windowUs,
    required this.startUs,
    required this.endUs,
  });

  static _Placement? of(
    VideoAudioTrack track,
    WaveformData waveform,
    Duration? videoDuration,
  ) {
    final peaksPerSecond = waveform.samplesPerSecond;
    if (peaksPerSecond <= 0 || waveform.sampleCount == 0) return null;
    final peaks = Float32List(waveform.sampleCount);
    final right = waveform.rightChannel;
    for (var i = 0; i < peaks.length; i++) {
      peaks[i] = right == null
          ? waveform.leftChannel[i]
          : math.max(waveform.leftChannel[i], right[i]);
    }

    final fileUs = (peaks.length * 1e6 / peaksPerSecond).round();
    final sourceStartUs = math.max(
      track.audioStartTime?.inMicroseconds ?? 0,
      0,
    );
    final sourceEndUs = math.min(
      track.audioEndTime?.inMicroseconds ?? fileUs,
      fileUs,
    );
    final windowUs = sourceEndUs - sourceStartUs;
    if (windowUs <= 0) return null;

    final startUs = math.max(track.startTime?.inMicroseconds ?? 0, 0);
    final playedUs = track.loop
        ? null
        : startUs + (windowUs / track.playbackSpeed).round();
    var endUs = track.endTime?.inMicroseconds;
    if (endUs == null) {
      if (playedUs != null) {
        endUs = playedUs;
      } else if (videoDuration != null) {
        endUs = videoDuration.inMicroseconds;
      } else {
        throw ArgumentError(
          'A looping track without an endTime needs the videoDuration',
        );
      }
    }
    if (videoDuration != null) {
      endUs = math.min(endUs, videoDuration.inMicroseconds);
    }
    // A track that plays once stops sounding where its audio runs out.
    if (playedUs != null) endUs = math.min(endUs, playedUs);
    if (endUs <= startUs) return null;

    return _Placement._(
      track: track,
      peaks: peaks,
      peaksPerSecond: peaksPerSecond,
      sourceStartUs: sourceStartUs,
      windowUs: windowUs,
      startUs: startUs,
      endUs: endUs,
    );
  }

  final VideoAudioTrack track;
  final Float32List peaks;
  final int peaksPerSecond;
  final int sourceStartUs;
  final int windowUs;
  final int startUs;

  /// Where the track stops sounding, which is also where its fade out ends.
  final int endUs;

  /// Raises [levels] to this track's level wherever it is louder.
  void addTo(Float32List levels, int levelsPerSecond) {
    final stepUs = 1e6 / levelsPerSecond;
    final first = (startUs / stepUs).floor();
    final last = math.min((endUs / stepUs).ceil(), levels.length);
    final speed = track.playbackSpeed;
    final fadeInUs = track.fadeInDuration.inMicroseconds;
    final fadeOutUs = track.fadeOutDuration.inMicroseconds;

    for (var step = first; step < last; step++) {
      final fromUs = math.max(step * stepUs, startUs.toDouble());
      final toUs = math.min((step + 1) * stepUs, endUs.toDouble());
      if (toUs <= fromUs) continue;
      final peak = _peakBetween(
        (fromUs - startUs) * speed,
        (toUs - startUs) * speed,
      );
      if (peak == 0) continue;

      final atUs = (fromUs + toUs) / 2;
      var gain = 1.0;
      if (fadeInUs > 0) gain = math.min(gain, (atUs - startUs) / fadeInUs);
      if (fadeOutUs > 0) gain = math.min(gain, (endUs - atUs) / fadeOutUs);
      final curve =
          track.volumeCurve?.volumeAt(Duration(microseconds: atUs.round())) ??
          1;
      final level = peak * track.volume * gain.clamp(0, 1) * curve;
      if (level > levels[step]) levels[step] = level;
    }
  }

  /// The highest peak the source plays between [fromUs] and [toUs] of its
  /// own (sped up or slowed down) playback, counted from the start of its
  /// source window.
  double _peakBetween(double fromUs, double toUs) {
    final firstPeak = (sourceStartUs * peaksPerSecond / 1e6).floor();
    final windowPeaks = math.max((windowUs * peaksPerSecond / 1e6).round(), 1);
    final from = (fromUs * peaksPerSecond / 1e6).floor();
    // The last peak that starts before [toUs]; the epsilon keeps a step that
    // ends exactly on a peak boundary from reading the next peak too.
    final to = math.max(
      (toUs * peaksPerSecond / 1e6 - 1e-9).floor() + 1,
      from + 1,
    );
    var peak = 0.0;
    for (var offset = from; offset < to; offset++) {
      var played = offset;
      if (track.loop) {
        played %= windowPeaks;
      } else if (played >= windowPeaks) {
        break;
      }
      final index = firstPeak + played;
      if (index < peaks.length && peaks[index] > peak) peak = peaks[index];
    }
    return peak;
  }
}
