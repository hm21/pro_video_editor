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
  VideoEffectType.oldFilm ||
  VideoEffectType.blockGlitch ||
  VideoEffectType.filmGrain ||
  VideoEffectType.signalInterference ||
  VideoEffectType.shake => videoEffectCycleLength,
  // Two seconds: the channels swap sides every second.
  VideoEffectType.rgbSplit => 2 * videoEffectFrameRate,
  VideoEffectType.pixelPulse ||
  VideoEffectType.negativeFlash => videoEffectFrameRate,
  VideoEffectType.strobe => _strobePeriod,
  VideoEffectType.zoomPulse => _zoomPulsePeriod,
  VideoEffectType.wave => _wavePeriodBuckets,
  VideoEffectType.pixelate ||
  VideoEffectType.vignette ||
  VideoEffectType.crt ||
  VideoEffectType.mirror ||
  VideoEffectType.kaleidoscope ||
  VideoEffectType.splitScreen ||
  VideoEffectType.glow => 1,
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
///
/// [intensity] is clamped to 0..1, and NaN counts as 0: `VideoEffect` only
/// asserts its range, so release builds can pass anything, and an infinite
/// size would crash the Apple renderer.
VideoEffectFrame videoEffectFrameFor(
  VideoEffectType type,
  double intensity,
  int bucket,
) {
  if (!(intensity > 0)) return VideoEffectFrame.none;
  intensity = math.min(intensity, 1.0);
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
    VideoEffectType.blockGlitch => _blockGlitch(intensity, bucket),
    VideoEffectType.filmGrain => _filmGrain(intensity, bucket),
    VideoEffectType.signalInterference => _signalInterference(
      intensity,
      bucket,
    ),
    VideoEffectType.crt => _crt(intensity),
    VideoEffectType.shake => _shake(intensity, bucket),
    VideoEffectType.zoomPulse => _zoomPulse(intensity, bucket),
    // The mirrored and repeated effects keep their symmetry at every
    // intensity: full intensity shows as much of the picture as fits, less
    // zooms in on its center, up to twice at the lowest.
    VideoEffectType.mirror => VideoEffectFrame(
      mirrorX: 0.5,
      zoom: 1 - intensity,
    ),
    VideoEffectType.kaleidoscope => VideoEffectFrame(
      mirrorX: 0.5,
      mirrorY: 0.5,
      zoom: 1 - intensity,
    ),
    VideoEffectType.splitScreen => VideoEffectFrame(
      tiles: 2,
      zoom: 1 - intensity,
    ),
    VideoEffectType.wave => _wave(intensity, bucket),
    // Only the brightest parts glow, from about two thirds of full brightness
    // on; more intensity glows stronger and from a little lower. The halo
    // spreads over about a tenth of the frame height.
    VideoEffectType.glow => VideoEffectFrame(
      glow: 2 * intensity,
      glowThreshold: 0.78 - 0.14 * intensity,
      glowRadius: 0.035,
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

/// An untouched picture broken by bursts in which it falls apart into coarse
/// blocks, one to three thick slices slip sideways and the color channels
/// jump apart.
///
/// The timeline is split into windows of six buckets (a quarter second). A
/// window bursts with a chance that grows with [intensity], for its first two
/// to four buckets. The first window always bursts, so the effect opens on a
/// burst. The block size holds for a whole burst; the slices and the channel
/// split change every bucket.
VideoEffectFrame _blockGlitch(double intensity, int bucket) {
  final window = bucket ~/ 6;
  final burstsHere = window == 0 || _random(30, window) < 0.2 + 0.3 * intensity;
  final burstLength = 2 + (_random(31, window) * 3).floor();
  if (!burstsHere || bucket - window * 6 >= burstLength) {
    return VideoEffectFrame.none;
  }

  final sign = _random(33, bucket) < 0.5 ? 1.0 : -1.0;
  final bands = <VideoEffectBand>[];
  final count = 1 + (_random(34, bucket) * 3).floor();
  for (var k = 0; k < count; k++) {
    final top = _random(35, bucket, k) * 0.9;
    final bottom = math.min(1.0, top + 0.06 + 0.18 * _random(36, bucket, k));
    final direction = _random(37, bucket, k) < 0.5 ? 1.0 : -1.0;
    final shift =
        direction * (0.04 + 0.12 * _random(38, bucket, k)) * intensity;
    final overlaps = bands.any((b) => bottom > b.top && top < b.bottom);
    if (!overlaps) {
      bands.add(VideoEffectBand(top: top, bottom: bottom, shift: shift));
    }
  }
  return VideoEffectFrame(
    pixelSize: (0.015 + 0.03 * _random(32, window)) * intensity,
    rgbShift: sign * (0.008 + 0.02 * _random(39, bucket)) * intensity,
    bands: bands,
  );
}

/// Fine grain of a constant strength that changes every bucket, like the
/// grain of a film print, and nothing else.
VideoEffectFrame _filmGrain(double intensity, int bucket) {
  const tile = VideoEffectFrame.noiseTileSize;
  return VideoEffectFrame(
    noise: 0.14 * intensity,
    noiseCellSize: 1 / 900,
    noiseOffsetX: (_random(40, bucket) * tile).floor(),
    noiseOffsetY: (_random(41, bucket) * tile).floor(),
  );
}

/// Two or three thin slices that land somewhere else every bucket and shift
/// sideways, and now and then a burst of noise with a slight color fringe.
///
/// Each slice stays in its own half or third of the frame, so they never
/// overlap. There are never more than three, so the slice of an effect that
/// runs at the same time, such as the tracking band of [VideoEffectType.vhs],
/// still fits within [VideoEffectFrame.maxBands].
///
/// Noise bursts follow windows of eight buckets (a third of a second): a
/// window bursts with a chance that grows with [intensity], for its first one
/// to three buckets. The first window always bursts.
VideoEffectFrame _signalInterference(double intensity, int bucket) {
  final bands = <VideoEffectBand>[];
  final count = 2 + (_random(50, bucket) * 2).floor();
  for (var k = 0; k < count; k++) {
    final height = 0.004 + 0.016 * _random(52, bucket, k);
    final top = (k + (1 - count * height) * _random(51, bucket, k)) / count;
    final direction = _random(53, bucket, k) < 0.5 ? 1.0 : -1.0;
    final shift =
        direction * (0.015 + 0.05 * _random(54, bucket, k)) * intensity;
    bands.add(VideoEffectBand(top: top, bottom: top + height, shift: shift));
  }

  final window = bucket ~/ 8;
  final burstsHere =
      window == 0 || _random(55, window) < 0.15 + 0.25 * intensity;
  final burstLength = 1 + (_random(56, window) * 3).floor();
  if (!burstsHere || bucket - window * 8 >= burstLength) {
    return VideoEffectFrame(bands: bands);
  }
  const tile = VideoEffectFrame.noiseTileSize;
  return VideoEffectFrame(
    rgbShift: 0.005 * intensity,
    noise: (0.3 + 0.2 * _random(57, bucket)) * intensity,
    noiseCellSize: 1 / 480,
    noiseOffsetX: (_random(58, bucket) * tile).floor(),
    noiseOffsetY: (_random(59, bucket) * tile).floor(),
    bands: bands,
  );
}

/// Strong, coarse scanlines with a slight color fringe and slightly darkened
/// corners. The picture is brightened a little, so the dark scanlines do not
/// darken it as a whole as much.
VideoEffectFrame _crt(double intensity) => VideoEffectFrame(
  rgbShift: 0.003 * intensity,
  scanlines: 0.55 * intensity,
  scanlinePeriod: 1 / 200,
  brightness: 0.12 * intensity,
  vignette: 0.35 * intensity,
  vignetteRadius: 0.45,
);

/// The picture jumps to a new spot every bucket, in a random direction, by up
/// to 2% of the frame at full [intensity]. It is zoomed in by a little more
/// than twice that, so its edges never come into view.
VideoEffectFrame _shake(double intensity, int bucket) {
  final reach = 0.02 * intensity;
  return VideoEffectFrame(
    zoom: 2.2 * reach,
    offsetX: (2 * _random(60, bucket) - 1) * reach,
    offsetY: (2 * _random(61, bucket) - 1) * reach,
  );
}

/// Buckets between two zoom punches: a beat at 120 beats a minute.
const int _zoomPulsePeriod = videoEffectFrameRate ~/ 2;

/// The picture punches in by up to 25% at the start of every half second and
/// eases back out until the next punch.
VideoEffectFrame _zoomPulse(double intensity, int bucket) {
  final remaining = 1 - (bucket % _zoomPulsePeriod) / _zoomPulsePeriod;
  return VideoEffectFrame(zoom: 0.25 * intensity * remaining * remaining);
}

/// Buckets the wave takes to roll up one wave length: two seconds.
const int _wavePeriodBuckets = 2 * videoEffectFrameRate;

/// Rows bend sideways by up to 2.5% of the frame width along a wave half the
/// frame tall, which rolls up the picture by one wave every two seconds. The
/// picture is zoomed in by a little more than twice the bend, so the edges the
/// rows move away from never come into view.
VideoEffectFrame _wave(double intensity, int bucket) {
  final amplitude = 0.025 * intensity;
  return VideoEffectFrame(
    zoom: 2.2 * amplitude,
    waveAmplitude: amplitude,
    wavePeriod: 0.5,
    wavePhase: bucket / _wavePeriodBuckets,
  );
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
