import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:pro_video_editor/core/models/video/video_effect_frame_model.dart';
import 'package:pro_video_editor/core/utils/video_effect_frames.dart';
import 'package:pro_video_editor/shared/models/time_range_mixin.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

/// The look a [VideoEffect] gives the video.
enum VideoEffectType {
  /// Digital distortion: the color channels jump apart in short bursts and
  /// slices of the picture slip sideways.
  glitch,

  /// A color fringe that punches out at the start of every second and settles
  /// back, with red and blue swapping sides each second.
  rgbSplit,

  /// A worn videotape: scanlines, moving grain, a slight color fringe and a
  /// tracking band that rolls up the picture.
  vhs,

  /// A badly tuned television: heavy flickering grain, fine scanlines and
  /// slices of the picture that now and then jump sideways.
  tvStatic,

  /// An old film print: sepia tones, fine grain, a flickering exposure and
  /// darkened corners.
  oldFilm,

  /// Large square pixels.
  pixelate,

  /// At the start of every second the picture breaks into large blocks that
  /// shrink until it is sharp again.
  pixelPulse,

  /// The picture flashes white twice a second and is dimmed in between.
  ///
  /// Two flashes a second stay below the three a second that WCAG 2.3.1 names
  /// as the limit for content that can trigger seizures, and a faster
  /// [VideoEffectParams.tempo] never goes past three. Flashing effects that
  /// overlap in time add their flashes up, so keep one of them active at a
  /// time to stay within it.
  strobe,

  /// The picture turns into its negative for a moment at the start of every
  /// second, twice in a row at higher intensities.
  ///
  /// At most two flashes a second, like [strobe], and like it only on its
  /// own: overlapping flashing effects add their flashes up.
  negativeFlash,

  /// Darkened corners that draw the eye to the center.
  vignette,

  /// A damaged video stream ("datamosh"): in short bursts the picture breaks
  /// into coarse blocks while slices of it slip sideways and the color
  /// channels jump apart. Untouched in between.
  blockGlitch,

  /// Fine, calm grain over the whole picture, for a subtle analog texture.
  filmGrain,

  /// A disturbed signal: thin slices that flicker and shift sideways, and now
  /// and then a burst of noise.
  signalInterference,

  /// An old CRT monitor: strong scanlines, a slight color fringe and slightly
  /// darkened corners. It does not move.
  crt,

  /// The picture jitters in every direction, like a handheld camera on a bass
  /// hit. It is zoomed in slightly, so its edges stay out of view.
  shake,

  /// The picture punches in at the start of every half second and eases back
  /// out.
  zoomPulse,

  /// The right half of the picture mirrors its left half, or with
  /// [VideoEffectParams.vertical] the bottom half its top half. Less
  /// intensity zooms in on the center.
  mirror,

  /// The picture mirrored into four symmetric parts: the right half mirrors
  /// the left and the bottom half the top. Less intensity zooms in on the
  /// center.
  kaleidoscope,

  /// The picture four times, in a 2×2 grid. Less intensity shows less of the
  /// picture in each copy, zoomed in on its center.
  splitScreen,

  /// The rows bend sideways along a wave that rolls up the picture, like a
  /// heat haze or a view through water. It is zoomed in slightly, so its
  /// edges stay out of view.
  wave,

  /// The brightest areas bloom softly into their surroundings, like stage
  /// lights or a sunset through a soft lens; the rest of the picture stays as
  /// it is. More intensity glows stronger and from slightly darker areas on.
  glow,
}

/// A visual effect that distorts the picture itself, unlike a [ColorFilter],
/// which only changes colors.
///
/// Effects move, split and replace pixels, and most of them change over time.
/// Their animation starts at [startTime] and repeats, after at most 20
/// seconds. With [triggers], the effect fires on given points in time
/// instead, for example on the beats of a song.
///
/// ```dart
/// VideoRenderData(
///   videoSegments: [VideoSegment(video: video)],
///   effects: [
///     const VideoEffect.glitch(
///       startTime: Duration(seconds: 2),
///       endTime: Duration(seconds: 3),
///     ),
///   ],
/// );
/// ```
///
/// Effects are applied to the video right before [VideoRenderData.colorFilters]
/// and are not applied to [VideoRenderData.imageLayers]. Show the same picture
/// in a live preview with `VideoEffectPreview`.
///
/// **Note:** Ignored on Web, Windows and Linux.
class VideoEffect with TimeRangeMixin {
  /// Creates an effect of [type].
  const VideoEffect({
    required this.type,
    this.intensity = 1,
    this.startTime,
    this.endTime,
    this.triggers = const [],
    this.params = const {},
  }) : assert(
         intensity >= 0 && intensity <= 1,
         'intensity must be between 0 and 1',
       );

  /// Creates a [VideoEffectType.glitch] effect.
  const VideoEffect.glitch({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.glitch,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.rgbSplit] effect.
  const VideoEffect.rgbSplit({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.rgbSplit,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.vhs] effect.
  const VideoEffect.vhs({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.vhs,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.tvStatic] effect.
  const VideoEffect.tvStatic({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.tvStatic,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.pixelPulse] effect.
  const VideoEffect.pixelPulse({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.pixelPulse,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.pixelate] effect.
  const VideoEffect.pixelate({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.pixelate,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.oldFilm] effect.
  const VideoEffect.oldFilm({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.oldFilm,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.strobe] effect.
  const VideoEffect.strobe({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.strobe,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.negativeFlash] effect.
  const VideoEffect.negativeFlash({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.negativeFlash,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.vignette] effect.
  const VideoEffect.vignette({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.vignette,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.blockGlitch] effect.
  const VideoEffect.blockGlitch({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.blockGlitch,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.filmGrain] effect.
  const VideoEffect.filmGrain({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.filmGrain,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.signalInterference] effect.
  const VideoEffect.signalInterference({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.signalInterference,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.crt] effect.
  const VideoEffect.crt({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.crt,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.shake] effect.
  const VideoEffect.shake({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.shake,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.zoomPulse] effect.
  const VideoEffect.zoomPulse({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.zoomPulse,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.mirror] effect.
  const VideoEffect.mirror({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.mirror,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.kaleidoscope] effect.
  const VideoEffect.kaleidoscope({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.kaleidoscope,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.splitScreen] effect.
  const VideoEffect.splitScreen({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.splitScreen,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.wave] effect.
  const VideoEffect.wave({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.wave,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates a [VideoEffectType.glow] effect.
  const VideoEffect.glow({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
    List<Duration> triggers = const [],
    Map<String, double> params = const {},
  }) : this(
         type: VideoEffectType.glow,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
         triggers: triggers,
         params: params,
       );

  /// Creates an effect from [toMap]'s output.
  ///
  /// An unknown [type] name throws an [ArgumentError].
  factory VideoEffect.fromMap(Map<String, dynamic> map) {
    return VideoEffect(
      type: VideoEffectType.values.byName(map['type'] as String),
      intensity: (tryParseDouble(map['intensity']) ?? 1).clamp(0.0, 1.0),
      startTime: map['startTime'] != null
          ? Duration(microseconds: safeParseInt(map['startTime']))
          : null,
      endTime: map['endTime'] != null
          ? Duration(microseconds: safeParseInt(map['endTime']))
          : null,
      triggers: [
        for (final trigger in map['triggers'] as List? ?? const [])
          Duration(microseconds: safeParseInt(trigger)),
      ],
      params: {
        for (final MapEntry(:key, :value)
            in (map['params'] as Map? ?? const {}).entries)
          if (tryParseDouble(value) case final number? when number.isFinite)
            '$key': number,
      },
    );
  }

  /// Creates an effect from [toJson]'s output.
  factory VideoEffect.fromJson(String source) =>
      VideoEffect.fromMap(json.decode(source) as Map<String, dynamic>);

  /// The look of the effect.
  final VideoEffectType type;

  /// How strong the effect is, from 0 (no change) to 1.
  final double intensity;

  /// When the effect starts, on the same timeline as
  /// [VideoRenderData.colorFilters]. `null` starts it with the video.
  @override
  final Duration? startTime;

  /// When the effect ends (exclusive). `null` keeps it until the end.
  ///
  /// An effect that does not end after it starts never applies.
  @override
  final Duration? endTime;

  /// When the effect fires, on the same timeline as [startTime], in any
  /// order. Empty plays the effect continuously.
  ///
  /// Otherwise the effect shows nothing until its first trigger, and from
  /// each trigger plays one hit from the start of its animation, for example
  /// on every beat of a song: one zoom punch, pixel pulse or RGB split pulse
  /// (on alternating sides), a glitch or block glitch burst that differs from
  /// hit to hit, the noise burst a signal interference opens with, one strobe
  /// flash without the dim and one negative flash without its echo. Every
  /// other effect plays a quarter second. A hit ends early where the next
  /// trigger starts the next one. A flashing effect flashes once per trigger,
  /// so keep triggers of [VideoEffectType.strobe] and
  /// [VideoEffectType.negativeFlash] at least a third of a second apart to
  /// stay within the three flashes a second that WCAG 2.3.1 allows.
  ///
  /// A trigger before [startTime] or at or after [endTime] does nothing. Each
  /// trigger lands on the nearest 1/120 s, counted from [startTime]: the
  /// renderers look a triggered effect up 120 times a second, so the preview
  /// and the export start a hit on the same frame.
  final List<Duration> triggers;

  /// How the effect looks beyond its [intensity], by the names in
  /// [VideoEffectParams]: for example how often a [VideoEffectType.glitch]
  /// bursts or how fast a [VideoEffectType.wave] rolls.
  ///
  /// Empty by default, which gives every effect its default look, as does a
  /// param it does not read or a missing one. Each param is clamped into its
  /// range, so no value breaks an effect, and a flashing effect stays within
  /// the three flashes a second that WCAG 2.3.1 allows whatever its tempo.
  /// NaN and infinite values count as missing, and [toMap] leaves them out.
  final Map<String, double> params;

  /// Whether the effect applies at [position].
  bool isActiveAt(Duration position) =>
      (startTime == null || position >= startTime!) &&
      (endTime == null || position < endTime!);

  /// The pixel operations the effect applies at [position], or
  /// [VideoEffectFrame.none] where it is not active.
  VideoEffectFrame frameAt(Duration position) {
    if (!isActiveAt(position)) return VideoEffectFrame.none;
    final start = startTime ?? Duration.zero;
    if (triggers.isNotEmpty) {
      return videoEffectTriggeredFrameFor(
        type,
        intensity,
        videoEffectTriggerSteps(triggers, start: start, end: endTime),
        videoEffectTriggerStepOf(position - start),
        params: params,
      );
    }
    final bucket = videoEffectBucketOf(type, position - start, params: params);
    return videoEffectFrameFor(type, intensity, bucket, params: params);
  }

  /// The combined pixel operations of every effect in [effects] that is
  /// active at [position]. See [VideoEffectFrame.merge].
  static VideoEffectFrame resolve(
    List<VideoEffect> effects,
    Duration position,
  ) {
    var frame = VideoEffectFrame.none;
    for (final effect in effects) {
      frame = frame.merge(effect.frameAt(position));
    }
    return frame;
  }

  /// Returns a copy with the given fields replaced.
  VideoEffect copyWith({
    VideoEffectType? type,
    double? intensity,
    Duration? startTime,
    Duration? endTime,
    List<Duration>? triggers,
    Map<String, double>? params,
  }) {
    return VideoEffect(
      type: type ?? this.type,
      intensity: intensity ?? this.intensity,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      triggers: triggers ?? this.triggers,
      params: params ?? this.params,
    );
  }

  /// Converts the effect into a map, for saving it.
  ///
  /// [params] that are NaN or infinite are left out: JSON cannot hold them,
  /// and the effect ignores them anyway.
  Map<String, dynamic> toMap() {
    final finiteParams = {
      for (final MapEntry(:key, :value) in params.entries)
        if (value.isFinite) key: value,
    };
    return <String, dynamic>{
      'type': type.name,
      'intensity': intensity,
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
      if (triggers.isNotEmpty)
        'triggers': [for (final trigger in triggers) trigger.inMicroseconds],
      if (finiteParams.isNotEmpty) 'params': finiteParams,
    };
  }

  /// Converts the effect into JSON.
  String toJson() => json.encode(toMap());

  @override
  bool operator ==(Object other) =>
      other is VideoEffect &&
      other.type == type &&
      other.intensity == intensity &&
      other.startTime == startTime &&
      other.endTime == endTime &&
      listEquals(other.triggers, triggers) &&
      mapEquals(other.params, params);

  @override
  int get hashCode => Object.hash(
    type,
    intensity,
    startTime,
    endTime,
    Object.hashAll(triggers),
    Object.hashAllUnordered(
      params.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );

  @override
  String toString() =>
      'VideoEffect(type: ${type.name}, intensity: $intensity, '
      'startTime: $startTime, endTime: $endTime, triggers: $triggers, '
      'params: $params)';
}

/// The names of the [VideoEffect.params] the effects read, each with the
/// effects that read it, its range, and its default.
///
/// Every param is optional: a missing one, or one an effect does not read,
/// keeps that effect's default look. Values outside a range are clamped into
/// it, and NaN and infinite values count as missing.
abstract final class VideoEffectParams {
  /// How often a [VideoEffectType.glitch], [VideoEffectType.blockGlitch] or
  /// [VideoEffectType.signalInterference] bursts, as a share of its default
  /// chance: 0 (only the first burst) to 2.5, 1 by default.
  static const frequency = 'frequency';

  /// How far the channels and slices of a [VideoEffectType.glitch] or the
  /// channels of an [VideoEffectType.rgbSplit] jump apart, or how far a
  /// [VideoEffectType.shake] moves, as a share of the default: 0.3 to 3.
  static const distance = 'distance';

  /// How fast an [VideoEffectType.rgbSplit] swaps sides or a
  /// [VideoEffectType.wave] rolls, as a share of the default: 0.25 to 4,
  /// within each effect's own limits. A [VideoEffectType.shake] reads it from
  /// 0.25 to 1, holding each spot for longer below 1. Does not apply to a hit
  /// of an effect with [VideoEffect.triggers].
  static const speed = 'speed';

  /// How often a [VideoEffectType.pixelPulse], [VideoEffectType.strobe] or
  /// [VideoEffectType.zoomPulse] repeats, as a share of the default: 0.25 to
  /// 4, within each effect's own limits. A strobe never flashes more than
  /// three times a second. Does not apply to a hit of an effect with
  /// [VideoEffect.triggers].
  static const tempo = 'tempo';

  /// How strong the scanlines of a [VideoEffectType.vhs] are, as a share of
  /// the default: 0.3 to 3.
  static const scanlines = 'scanlines';

  /// How strong the grain of a [VideoEffectType.vhs] or a
  /// [VideoEffectType.tvStatic] is, as a share of the default: 0.3 to 3.
  static const noise = 'noise';

  /// How coarse the grain of a [VideoEffectType.tvStatic] or a
  /// [VideoEffectType.filmGrain] is, as a share of the default: 0.3 to 4.
  static const grainSize = 'grainSize';

  /// How brown an [VideoEffectType.oldFilm] turns, as a share of the
  /// default: 0 to 3, at most full sepia.
  static const sepia = 'sepia';

  /// How much an [VideoEffectType.oldFilm]'s exposure flickers, as a share of
  /// the default: 0 to 1.25, so at most 5% either way, which keeps every
  /// change below the 10% that WCAG 2.3.1 counts as a flash.
  static const flicker = 'flicker';

  /// How dark an [VideoEffectType.oldFilm]'s corners get, as a share of the
  /// default: 0 to 3.
  static const vignette = 'vignette';

  /// How large the pixels of a [VideoEffectType.pixelate] are, or the clear
  /// middle of a [VideoEffectType.vignette], as a share of the default: 0.3
  /// to 3.
  static const size = 'size';

  /// How long a [VideoEffectType.negativeFlash] lasts, as a share of the
  /// default: 0.3 to 3, ending before its echo.
  static const length = 'length';

  /// How coarse the blocks of a [VideoEffectType.blockGlitch] are, as a share
  /// of the default: 0.3 to 3.
  static const blockSize = 'blockSize';

  /// How close together the scanlines of a [VideoEffectType.crt] lie, as a
  /// share of the default: 0.3 to 3.
  static const density = 'density';

  /// 1 to mirror a [VideoEffectType.mirror]'s top half onto its bottom one
  /// instead of its left half onto its right one; 0 by default.
  static const vertical = 'vertical';

  /// How tall a [VideoEffectType.wave]'s waves are, as a share of the default
  /// half frame: 0.25 to 3.
  static const wavelength = 'wavelength';

  /// How readily a [VideoEffectType.glow] glows: 0 to 1, 0.5 by default;
  /// higher glows from darker parts on.
  static const threshold = 'threshold';

  /// How far a [VideoEffectType.glow]'s halo spreads, as a share of the
  /// default: 0.3 to 3.
  static const radius = 'radius';
}
