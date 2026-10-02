import 'dart:convert';

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
  /// as the limit for content that can trigger seizures. Flashing effects that
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

  /// The picture jitters in every direction, like a handheld camera on a bass
  /// hit. It is zoomed in slightly, so its edges stay out of view.
  shake,

  /// The picture punches in at the start of every half second and eases back
  /// out.
  zoomPulse,

  /// The right half of the picture mirrors its left half. Less intensity
  /// zooms in on the center.
  mirror,

  /// The picture mirrored into four symmetric parts: the right half mirrors
  /// the left and the bottom half the top. Less intensity zooms in on the
  /// center.
  kaleidoscope,

  /// The picture four times, in a 2×2 grid. Less intensity shows less of the
  /// picture in each copy, zoomed in on its center.
  splitScreen,

  /// The rows bend sideways along a wave that rolls up the picture, like a
  /// heat haze or a view through water.
  wave,
}

/// A visual effect that distorts the picture itself, unlike a [ColorFilter],
/// which only changes colors.
///
/// Effects move, split and replace pixels, and most of them change over time.
/// Their animation starts at [startTime] and repeats, after at most 20
/// seconds.
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
  }) : assert(
         intensity >= 0 && intensity <= 1,
         'intensity must be between 0 and 1',
       );

  /// Creates a [VideoEffectType.glitch] effect.
  const VideoEffect.glitch({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.glitch,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.rgbSplit] effect.
  const VideoEffect.rgbSplit({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.rgbSplit,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.vhs] effect.
  const VideoEffect.vhs({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.vhs,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.tvStatic] effect.
  const VideoEffect.tvStatic({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.tvStatic,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.pixelPulse] effect.
  const VideoEffect.pixelPulse({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.pixelPulse,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.pixelate] effect.
  const VideoEffect.pixelate({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.pixelate,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.oldFilm] effect.
  const VideoEffect.oldFilm({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.oldFilm,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.strobe] effect.
  const VideoEffect.strobe({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.strobe,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.negativeFlash] effect.
  const VideoEffect.negativeFlash({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.negativeFlash,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.vignette] effect.
  const VideoEffect.vignette({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.vignette,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.shake] effect.
  const VideoEffect.shake({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.shake,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.zoomPulse] effect.
  const VideoEffect.zoomPulse({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.zoomPulse,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.mirror] effect.
  const VideoEffect.mirror({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.mirror,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.kaleidoscope] effect.
  const VideoEffect.kaleidoscope({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.kaleidoscope,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.splitScreen] effect.
  const VideoEffect.splitScreen({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.splitScreen,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
       );

  /// Creates a [VideoEffectType.wave] effect.
  const VideoEffect.wave({
    double intensity = 1,
    Duration? startTime,
    Duration? endTime,
  }) : this(
         type: VideoEffectType.wave,
         intensity: intensity,
         startTime: startTime,
         endTime: endTime,
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

  /// Whether the effect applies at [position].
  bool isActiveAt(Duration position) =>
      (startTime == null || position >= startTime!) &&
      (endTime == null || position < endTime!);

  /// The pixel operations the effect applies at [position], or
  /// [VideoEffectFrame.none] where it is not active.
  VideoEffectFrame frameAt(Duration position) {
    if (!isActiveAt(position)) return VideoEffectFrame.none;
    final bucket = videoEffectBucketOf(
      type,
      position - (startTime ?? Duration.zero),
    );
    return videoEffectFrameFor(type, intensity, bucket);
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
  }) {
    return VideoEffect(
      type: type ?? this.type,
      intensity: intensity ?? this.intensity,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
    );
  }

  /// Converts the effect into a map, for saving it.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'type': type.name,
      'intensity': intensity,
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
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
      other.endTime == endTime;

  @override
  int get hashCode => Object.hash(type, intensity, startTime, endTime);

  @override
  String toString() =>
      'VideoEffect(type: ${type.name}, intensity: $intensity, '
      'startTime: $startTime, endTime: $endTime)';
}
