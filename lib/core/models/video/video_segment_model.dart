// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';

import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

/// Represents a single video clip to be included in a video composition.
///
/// Each clip can have its own start and end time for trimming.
/// Multiple clips can be combined to create a concatenated video.
class VideoSegment {
  /// Creates a [VideoSegment] with the given parameters.
  const VideoSegment({
    required this.video,
    this.startTime,
    this.endTime,
    this.volume,
    this.equalizer,
    this.playbackSpeed,
    this.speedRamp,
    this.reverseVideo = false,
    this.transition,
    this.timelineStart,
    this.transform,
    this.chromaKey,
    this.stabilization,
  }) : assert(
         stabilization == null ||
             (!reverseVideo &&
                 chromaKey == null &&
                 speedRamp == null &&
                 (playbackSpeed == null || playbackSpeed == 1)),
         '[stabilization] cannot be combined with a playback speed, a speed '
         'ramp, reverseVideo or a chroma key yet',
       ),
       assert(
         speedRamp == null || playbackSpeed == null,
         'Set either [playbackSpeed] or [speedRamp], not both',
       ),
       assert(
         startTime == null || endTime == null || startTime < endTime,
         'startTime must be before endTime',
       ),
       assert(
         volume == null || volume >= 0,
         '[volume] must be greater than or equal to 0',
       ),
       assert(
         playbackSpeed == null || playbackSpeed > 0,
         '[playbackSpeed] must be greater than 0',
       );

  /// The video source for this clip.
  ///
  /// This class supports videos from in-memory bytes, file system, network,
  /// or asset bundle.
  final EditorVideo video;

  /// Optional start time for trimming this clip.
  ///
  /// If null, the clip starts from the beginning of the video.
  final Duration? startTime;

  /// Optional end time for trimming this clip.
  ///
  /// If null, the clip plays until the end of the video.
  final Duration? endTime;

  /// Volume multiplier for this segment's audio.
  ///
  /// - `0.0`: Mute
  /// - `1.0`: Original volume
  /// - `> 1.0`: Amplified; peaks that would pass -1 dBFS are limited
  ///   rather than clipped
  ///
  /// If null, the original volume is used.
  final double? volume;

  /// Raises or lowers parts of the frequency range of this segment's audio.
  ///
  /// Applied before [volume], so a boosted equalizer that is limited at
  /// -1 dBFS still follows the volume from there.
  ///
  /// If null, the audio is left as it is.
  final AudioEqualizer? equalizer;

  /// Playback speed of this segment.
  ///
  /// For example, `0.5` for half speed, `2.0` for double speed.
  ///
  /// If null, the original speed is used.
  ///
  /// **Not supported inside a [VideoComposition]:** per-clip playback speed is
  /// ignored for composition clips. Pre-render the speed change into the source
  /// or use [videoSegments] instead.
  final double? playbackSpeed;

  /// A speed that changes while this segment plays, instead of the one
  /// constant [playbackSpeed].
  ///
  /// Its points run along the segment from [startTime] to [endTime], in the
  /// order the segment plays. [VideoSpeedRamp.outputDuration] tells how long
  /// the segment plays with it, and [VideoRenderData.startTime] and
  /// [VideoRenderData.endTime] are measured after it, like after a constant
  /// speed.
  ///
  /// Inside an overlap [transition] each side plays its stretch of the ramp at
  /// that stretch's average speed.
  ///
  /// If null, the segment plays at [playbackSpeed].
  ///
  /// **Not supported inside a [VideoComposition]:** like [playbackSpeed], a
  /// speed ramp is ignored for composition clips.
  final VideoSpeedRamp? speedRamp;

  /// Whether to render this segment backwards.
  ///
  /// When `true`, this segment plays from its trimmed end back to its trimmed
  /// start. Other segments keep their own order and direction.
  ///
  /// **Default**: `false`
  ///
  /// **Not supported inside a [VideoComposition]:** reverse playback is ignored
  /// for composition clips. Pre-render the reversed source or use
  /// [videoSegments] instead.
  final bool reverseVideo;

  /// The transition played between this clip and the **next** clip.
  ///
  /// Describes how this segment transitions into the following segment (e.g. a
  /// dissolve or fade-to-black).
  ///
  /// **On the last (or only) segment** there is no following clip, so the
  /// transition instead **wraps back into the first segment**, turning the
  /// whole track into a seamless loop: the end dissolves (or dips) into the
  /// beginning, so a looping player restarts without a visible cut. For overlap
  /// transitions ([ClipTransitionType.isOverlap]) the output is shortened by
  /// the transition duration — exactly like an overlap transition between two
  /// clips — and for a single segment the clip must be longer than twice the
  /// transition duration (otherwise the wrap is skipped and the loop restarts
  /// hard). Dip transitions (fadeToBlack/fadeToWhite) keep the duration and dip
  /// through the color at the restart seam.
  ///
  /// Currently supported on Android and iOS/macOS only; other platforms
  /// ignore this field.
  ///
  /// **Not supported inside a [VideoComposition]:** transitions are ignored for
  /// composition clips. Use [videoSegments] when you need clip transitions.
  final ClipTransition? transition;

  /// Start position of this clip on its layer's timeline.
  ///
  /// Only used when the segment is part of a [VideoComposition]. It defines
  /// when the clip begins relative to the start of the composition. Any gap
  /// before it is filled with the composition's background.
  ///
  /// When `null`, the clip starts right after the previous clip on the same
  /// layer (back-to-back concatenation).
  final Duration? timelineStart;

  /// Position and scale of this clip within the composition canvas.
  ///
  /// Only used when the segment is part of a [VideoComposition]. Overrides the
  /// [VideoLayer.transform]. When `null`, the clip uses its layer's transform,
  /// or fills the entire canvas if neither is set.
  final SegmentTransform? transform;

  /// Removes a solid-colored background from this clip only.
  ///
  /// Overrides [VideoLayer.chromaKey] and [VideoRenderData.chromaKey] for this
  /// clip; the three are never merged. When `null`, the clip falls back to its
  /// layer's key, then to the global one.
  ///
  /// **Ignored inside an overlap [transition]**
  /// ([ClipTransitionType.isOverlap]) when the two clips at that boundary
  /// carry different keys — that blend is pre-rendered from the raw sources
  /// and is emitted unkeyed with a warning.
  final ChromaKey? chromaKey;

  /// Steadies this clip's shake with per-frame transforms, typically from a
  /// `VideoStabilizationAnalyzer` run over the clip's frames.
  ///
  /// Each frame takes the keyframe of its own source timestamp, so the
  /// transforms stay attached to the right frames whatever [startTime] the
  /// clip is trimmed to; frames the analysis skipped are interpolated, and
  /// frames outside the keyframes' range hold the nearest one. The frame is
  /// moved before the render's crop, rotation and layers.
  ///
  /// Currently supported on Android and iOS/macOS for [videoSegments] only;
  /// ignored inside a [VideoComposition], and not yet combined with
  /// [playbackSpeed], [speedRamp], [reverseVideo], [chromaKey] or an overlap
  /// [transition].
  final VideoStabilization? stabilization;

  /// Converts this clip to a map for platform channel communication.
  ///
  /// Resolves the input path and any chroma-key background image, so this is
  /// asynchronous.
  Future<Map<String, dynamic>> toAsyncMap() async {
    final inputPath = await video.contentOrSafeFilePath();

    return {
      'inputPath': inputPath,
      'startUs': startTime?.inMicroseconds,
      'endUs': endTime?.inMicroseconds,
      'volume': volume,
      'equalizer': equalizer?.toMap(),
      'playbackSpeed': playbackSpeed,
      'speedRamp': speedRamp?.toChannelSteps(),
      'reverseVideo': reverseVideo,
      'transition': transition?.toMap(),
      'timelineStartUs': timelineStart?.inMicroseconds,
      'transform': transform?.toMap(),
      'chromaKey': await chromaKey?.toAsyncMap(),
      'stabilization': stabilization?.toMap(),
    };
  }

  /// Creates a copy with updated values.
  ///
  /// A segment plays at either a [playbackSpeed] or a [speedRamp], so passing
  /// one of them drops the other.
  VideoSegment copyWith({
    EditorVideo? video,
    Duration? startTime,
    Duration? endTime,
    double? volume,
    AudioEqualizer? equalizer,
    double? playbackSpeed,
    VideoSpeedRamp? speedRamp,
    bool? reverseVideo,
    ClipTransition? transition,
    Duration? timelineStart,
    SegmentTransform? transform,
    ChromaKey? chromaKey,
    VideoStabilization? stabilization,
  }) {
    return VideoSegment(
      video: video ?? this.video,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      volume: volume ?? this.volume,
      equalizer: equalizer ?? this.equalizer,
      playbackSpeed:
          playbackSpeed ?? (speedRamp == null ? this.playbackSpeed : null),
      speedRamp: speedRamp ?? (playbackSpeed == null ? this.speedRamp : null),
      reverseVideo: reverseVideo ?? this.reverseVideo,
      transition: transition ?? this.transition,
      timelineStart: timelineStart ?? this.timelineStart,
      transform: transform ?? this.transform,
      chromaKey: chromaKey ?? this.chromaKey,
      stabilization: stabilization ?? this.stabilization,
    );
  }

  @override
  bool operator ==(covariant VideoSegment other) {
    if (identical(this, other)) return true;

    return other.video == video &&
        other.startTime == startTime &&
        other.endTime == endTime &&
        other.volume == volume &&
        other.equalizer == equalizer &&
        other.playbackSpeed == playbackSpeed &&
        other.speedRamp == speedRamp &&
        other.reverseVideo == reverseVideo &&
        other.transition == transition &&
        other.timelineStart == timelineStart &&
        other.transform == transform &&
        other.chromaKey == chromaKey &&
        other.stabilization == stabilization;
  }

  @override
  int get hashCode {
    return video.hashCode ^
        startTime.hashCode ^
        endTime.hashCode ^
        volume.hashCode ^
        equalizer.hashCode ^
        playbackSpeed.hashCode ^
        speedRamp.hashCode ^
        reverseVideo.hashCode ^
        transition.hashCode ^
        timelineStart.hashCode ^
        transform.hashCode ^
        chromaKey.hashCode ^
        stabilization.hashCode;
  }

  @override
  String toString() {
    return 'VideoSegment(video: $video, '
        'startTime: $startTime, '
        'endTime: $endTime, '
        'volume: $volume, '
        'equalizer: $equalizer, '
        'playbackSpeed: $playbackSpeed, '
        'speedRamp: $speedRamp, '
        'reverseVideo: $reverseVideo, '
        'transition: $transition, '
        'timelineStart: $timelineStart, '
        'transform: $transform, '
        'chromaKey: $chromaKey, '
        'stabilization: $stabilization)';
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'video': video.toMap(),
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
      'volume': volume,
      'equalizer': equalizer?.toMap(),
      'playbackSpeed': playbackSpeed,
      'speedRamp': speedRamp?.toMap(),
      'reverseVideo': reverseVideo,
      'transition': transition?.toMap(),
      'timelineStart': timelineStart?.inMicroseconds,
      'transform': transform?.toMap(),
      'chromaKey': chromaKey?.toMap(),
      'stabilization': stabilization?.toMap(),
    };
  }

  factory VideoSegment.fromMap(Map<String, dynamic> map) {
    return VideoSegment(
      video: EditorVideo.fromMap(map['video'] as Map<String, dynamic>),
      startTime: map['startTime'] != null
          ? Duration(microseconds: safeParseInt(map['startTime']))
          : null,
      endTime: map['endTime'] != null
          ? Duration(microseconds: safeParseInt(map['endTime']))
          : null,
      volume: tryParseDouble(map['volume']),
      equalizer: map['equalizer'] != null
          ? AudioEqualizer.fromMap(map['equalizer'] as Map<String, dynamic>)
          : null,
      playbackSpeed: tryParseDouble(map['playbackSpeed']),
      speedRamp: map['speedRamp'] != null
          ? VideoSpeedRamp.fromMap(map['speedRamp'] as Map<String, dynamic>)
          : null,
      reverseVideo: map['reverseVideo'] as bool? ?? false,
      transition: map['transition'] != null
          ? ClipTransition.fromMap(map['transition'] as Map<String, dynamic>)
          : null,
      timelineStart: map['timelineStart'] != null
          ? Duration(microseconds: safeParseInt(map['timelineStart']))
          : null,
      transform: map['transform'] != null
          ? SegmentTransform.fromMap(map['transform'] as Map<String, dynamic>)
          : null,
      chromaKey: map['chromaKey'] != null
          ? ChromaKey.fromMap(map['chromaKey'] as Map<String, dynamic>)
          : null,
      stabilization: map['stabilization'] != null
          ? VideoStabilization.fromMap(
              map['stabilization'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory VideoSegment.fromJson(String source) =>
      VideoSegment.fromMap(json.decode(source) as Map<String, dynamic>);
}
