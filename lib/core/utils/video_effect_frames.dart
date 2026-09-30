import 'dart:math' as math;

import '/core/models/video/video_effect_frame_model.dart';
import '/core/models/video/video_effect_model.dart';

/// Frames per second at which an effect's look changes.
///
/// The native renderers look an effect up at this rate, so a preview that
/// shows the frame for the same bucket shows the same picture.
const int videoEffectFrameRate = 24;

/// Buckets after which an animated effect repeats (20 seconds).
const int videoEffectCycleLength = 480;

/// The number of buckets [videoEffectFrameFor] cycles through for [type].
int videoEffectCycleLengthOf(VideoEffectType type) => switch (type) {
  VideoEffectType.glitch ||
  VideoEffectType.vhs ||
  VideoEffectType.tvStatic ||
  VideoEffectType.oldFilm => videoEffectCycleLength,
  // Two seconds: the channels swap sides every second.
  VideoEffectType.rgbSplit => 2 * videoEffectFrameRate,
  VideoEffectType.pixelPulse ||
  VideoEffectType.negativeFlash => videoEffectFrameRate,
  VideoEffectType.strobe => _strobePeriod,
  VideoEffectType.pixelate || VideoEffectType.vignette => 1,
};

/// The bucket of [localTime] into [type]'s cycle.
///
/// [localTime] counts from the effect's start and must not be negative.
int videoEffectBucketOf(VideoEffectType type, Duration localTime) {
  final bucket =
      localTime.inMicroseconds *
      videoEffectFrameRate ~/
      Duration.microsecondsPerSecond;
  return bucket % videoEffectCycleLengthOf(type);
}

/// The frame of [type] at [intensity] for [bucket].
///
/// Deterministic: the same arguments always give the same frame, on every
/// platform, which is what keeps a preview and an export in step.
VideoEffectFrame videoEffectFrameFor(
  VideoEffectType type,
  double intensity,
  int bucket,
) {
  if (intensity <= 0) return VideoEffectFrame.none;
  return switch (type) {
    VideoEffectType.glitch => _glitch(intensity, bucket),
    VideoEffectType.rgbSplit => _rgbSplit(intensity, bucket),
    VideoEffectType.vhs => _vhs(intensity, bucket),
    VideoEffectType.tvStatic => _tvStatic(intensity, bucket),
    VideoEffectType.oldFilm => _oldFilm(intensity, bucket),
    VideoEffectType.pixelate => VideoEffectFrame(pixelSize: 0.05 * intensity),
    VideoEffectType.pixelPulse => _pixelPulse(intensity, bucket),
    VideoEffectType.strobe => _strobe(intensity, bucket),
    VideoEffectType.negativeFlash => _negativeFlash(intensity, bucket),
    // More intensity darkens more and starts closer to the center. Past 1 the
    // corners are already black and the black spreads inward: at full strength
    // everything beyond about 88% of the way to the corners.
    VideoEffectType.vignette => VideoEffectFrame(
      vignette: 1.3 * intensity,
      vignetteRadius: 0.4 - 0.3 * intensity,
    ),
  };
}

/// Every frame of [type]'s cycle, flattened for the native renderers.
List<double> bakeVideoEffectFrames(VideoEffectType type, double intensity) {
  final length = videoEffectCycleLengthOf(type);
  return [
    for (var bucket = 0; bucket < length; bucket++)
      ...videoEffectFrameFor(type, intensity, bucket).toList(),
  ];
}

/// Calm stretches with a slight color fringe, broken by bursts in which the
/// channels jump apart and one to three slices of the picture slip sideways.
///
/// The timeline is split into windows of four buckets (a sixth of a second).
/// A window bursts with a chance that grows with [intensity], for its first
/// one to three buckets. The first window always bursts, so the effect opens
/// on a glitch.
VideoEffectFrame _glitch(double intensity, int bucket) {
  final window = bucket ~/ 4;
  final burstsHere =
      window == 0 || _random(1, window) < 0.25 + 0.35 * intensity;
  final burstLength = 1 + (_random(2, window) * 3).floor();
  if (!burstsHere || bucket - window * 4 >= burstLength) {
    return VideoEffectFrame(rgbShift: 0.0025 * intensity);
  }

  final sign = _random(3, bucket) < 0.5 ? 1.0 : -1.0;
  final bands = <VideoEffectBand>[];
  final count = 1 + (_random(5, bucket) * 3).floor();
  for (var k = 0; k < count; k++) {
    final top = _random(6, bucket, k) * 0.95;
    final height = 0.015 + 0.12 * math.pow(_random(7, bucket, k), 2);
    final bottom = math.min(1.0, top + height);
    final direction = _random(8, bucket, k) < 0.5 ? 1.0 : -1.0;
    final shift = direction * (0.02 + 0.10 * _random(9, bucket, k)) * intensity;
    final overlaps = bands.any((b) => bottom > b.top && top < b.bottom);
    if (!overlaps) {
      bands.add(VideoEffectBand(top: top, bottom: bottom, shift: shift));
    }
  }
  return VideoEffectFrame(
    rgbShift: sign * (0.006 + 0.018 * _random(4, bucket)) * intensity,
    bands: bands,
  );
}

/// Scanlines, grain that changes every bucket, a slight color fringe, and a
/// tracking band that rolls up the picture for 2.5 s of every 7.5 s.
VideoEffectFrame _vhs(double intensity, int bucket) {
  final phase = bucket % 180;
  final bands = <VideoEffectBand>[];
  if (phase < 60) {
    final top = 1.05 - phase / 60 * 1.2;
    final bottom = top + 0.04 + 0.02 * intensity;
    final shift =
        (0.006 + 0.012 * intensity) * (0.8 + 0.4 * _random(3, bucket));
    final clippedTop = math.max(0.0, top);
    final clippedBottom = math.min(1.0, bottom);
    if (clippedBottom > clippedTop) {
      bands.add(
        VideoEffectBand(top: clippedTop, bottom: clippedBottom, shift: shift),
      );
    }
  }
  const tile = VideoEffectFrame.noiseTileSize;
  return VideoEffectFrame(
    rgbShift: 0.006 * intensity,
    scanlines: 0.30 * intensity,
    scanlinePeriod: 1 / 270,
    noise: 0.22 * intensity,
    noiseCellSize: 1 / 540,
    noiseOffsetX: (_random(1, bucket) * tile).floor(),
    noiseOffsetY: (_random(2, bucket) * tile).floor(),
    bands: bands,
  );
}

/// A color fringe that punches out at the start of every second and settles
/// back to a quarter of its size, with red and blue swapping sides each second.
VideoEffectFrame _rgbSplit(double intensity, int bucket) {
  final phase = bucket % videoEffectFrameRate;
  final punch = math.exp(-5 * phase / videoEffectFrameRate);
  final side = (bucket ~/ videoEffectFrameRate).isEven ? 1.0 : -1.0;
  return VideoEffectFrame(
    rgbShift: side * 0.02 * intensity * (0.25 + 0.75 * punch),
  );
}

/// A badly tuned television: heavy grain that flickers every bucket, fine
/// scanlines, a slight fringe, and now and then one or two slices of the
/// picture jumping sideways.
VideoEffectFrame _tvStatic(double intensity, int bucket) {
  final bands = <VideoEffectBand>[];
  if (_random(10, bucket) < 0.12) {
    final count = 1 + (_random(11, bucket) * 2).floor();
    for (var k = 0; k < count; k++) {
      final top = _random(12, bucket, k) * 0.9;
      final bottom = math.min(1.0, top + 0.04 + 0.2 * _random(13, bucket, k));
      final direction = _random(14, bucket, k) < 0.5 ? 1.0 : -1.0;
      final shift =
          direction * (0.02 + 0.06 * _random(15, bucket, k)) * intensity;
      final overlaps = bands.any((b) => bottom > b.top && top < b.bottom);
      if (!overlaps) {
        bands.add(VideoEffectBand(top: top, bottom: bottom, shift: shift));
      }
    }
  }
  const tile = VideoEffectFrame.noiseTileSize;
  return VideoEffectFrame(
    rgbShift: 0.004 * intensity,
    scanlines: 0.2 * intensity,
    scanlinePeriod: 1 / 300,
    noise: (0.45 + 0.2 * _random(16, bucket)) * intensity,
    noiseCellSize: 1 / 400,
    noiseOffsetX: (_random(17, bucket) * tile).floor(),
    noiseOffsetY: (_random(18, bucket) * tile).floor(),
    bands: bands,
  );
}

/// At the start of every second the picture breaks into large blocks that
/// shrink until it is sharp again, ten buckets (about 0.4 s) later.
VideoEffectFrame _pixelPulse(double intensity, int bucket) {
  const resolveBuckets = 10;
  final phase = bucket % videoEffectFrameRate;
  if (phase >= resolveBuckets) return VideoEffectFrame.none;
  final remaining = 1 - phase / resolveBuckets;
  return VideoEffectFrame(pixelSize: 0.09 * intensity * remaining * remaining);
}

/// Sepia tones, fine grain that changes every bucket, an exposure that
/// flickers by up to 4% either way, and darkened corners.
///
/// The flicker stays below the 10% change that WCAG 2.3.1 counts as a flash.
VideoEffectFrame _oldFilm(double intensity, int bucket) {
  const tile = VideoEffectFrame.noiseTileSize;
  return VideoEffectFrame(
    noise: 0.16 * intensity,
    noiseCellSize: 1 / 480,
    noiseOffsetX: (_random(20, bucket) * tile).floor(),
    noiseOffsetY: (_random(21, bucket) * tile).floor(),
    sepia: 0.85 * intensity,
    brightness: (_random(22, bucket) - 0.5) * 0.08 * intensity,
    vignette: 0.6 * intensity,
    vignetteRadius: 0.3,
  );
}

/// Buckets between two strobe flashes: two flashes a second, below the three
/// a second that WCAG 2.3.1 allows.
const int _strobePeriod = videoEffectFrameRate ~/ 2;

/// A white flash at the start of every half second that fades out over the
/// next two buckets, with the picture dimmed in between so the flashes stand
/// out, like a strobe light in a dark room.
///
/// [intensity] sets both how bright the flash gets, fully white from 0.75
/// on, and how far the picture is dimmed between flashes, down to half.
VideoEffectFrame _strobe(double intensity, int bucket) {
  final peak = math.min(1.0, 0.25 + intensity);
  return switch (bucket % _strobePeriod) {
    0 => VideoEffectFrame(flash: peak),
    1 => VideoEffectFrame(flash: 0.55 * peak),
    2 => VideoEffectFrame(flash: 0.2 * peak),
    _ => VideoEffectFrame(brightness: -0.5 * intensity),
  };
}

/// The negative for the first one to four buckets of every second, longer
/// with more [intensity]. From half intensity on, a one-bucket echo follows a
/// quarter second later, so there are at most two flashes a second.
VideoEffectFrame _negativeFlash(double intensity, int bucket) {
  final phase = bucket % videoEffectFrameRate;
  final length = 1 + (3 * intensity).round();
  final echo = intensity >= 0.5 && phase == videoEffectFrameRate ~/ 4;
  if (phase < length || echo) return const VideoEffectFrame(invert: 1);
  return VideoEffectFrame.none;
}

/// A uniform value in `[0, 1)` for the given keys.
double _random(int a, int b, [int c = 0]) {
  var h = 0x9e3779b9;
  h = _hash(h ^ a);
  h = _hash(h ^ b);
  h = _hash(h ^ c);
  return h / 4294967296.0;
}

/// Chris Wellons' lowbias32 integer hash.
int _hash(int value) {
  var x = value & 0xffffffff;
  x ^= x >> 16;
  x = _multiply32(x, 0x7feb352d);
  x ^= x >> 15;
  x = _multiply32(x, 0x846ca68b);
  x ^= x >> 16;
  return x;
}

/// `a * b` modulo 2^32, exact on the web too, where a full 64-bit product
/// would lose its low bits to double precision.
int _multiply32(int a, int b) {
  final low = (a & 0xffff) * b;
  final high = (((a >> 16) & 0xffff) * b) & 0xffff;
  return (low + (high << 16)) & 0xffffffff;
}
