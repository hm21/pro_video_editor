// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:pro_video_editor/core/models/image/keyframe_clock_point_model.dart'
    show keyframeClockFromMap;
import 'package:pro_video_editor/core/models/image/timeline_keyframe_model.dart'
    show sortTimelineKeyframes;
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';

/// A single layer (track) within a [VideoComposition].
///
/// A layer holds a time-ordered sequence of [clips]. Clips on the same layer
/// are placed along the timeline via [VideoSegment.timelineStart] and never
/// overlap each other; consecutive clips may use a [VideoSegment.transition].
///
/// Layers are composited bottom-to-top in the order they appear in
/// [VideoComposition.layers], so a later layer is drawn on top of an earlier
/// one (its z-order). The whole layer is rendered with [opacity] and, unless a
/// clip provides its own [VideoSegment.transform], placed using [transform].
class VideoLayer {
  /// Creates a [VideoLayer] from a list of [clips].
  const VideoLayer({
    required this.clips,
    this.opacity = 1.0,
    this.transform,
    this.chromaKey,
    this.keyframes = const [],
    this.keyframeClock = const [],
  }) : assert(clips.length > 0, 'A layer must contain at least one clip'),
       assert(
         opacity >= 0 && opacity <= 1,
         '[opacity] must be between 0 and 1',
       );

  /// The time-ordered sequence of clips on this layer.
  final List<VideoSegment> clips;

  /// Opacity applied to the entire layer.
  ///
  /// - `0.0`: fully transparent
  /// - `1.0`: fully opaque (default)
  final double opacity;

  /// Default placement for clips on this layer within the composition canvas.
  ///
  /// A clip with its own [VideoSegment.transform] overrides this. When `null`,
  /// clips fill the entire canvas unless they define their own transform.
  final SegmentTransform? transform;

  /// Default chroma key for the clips on this layer.
  ///
  /// This is a **default for the clips**, not a post-composite effect: each
  /// clip is keyed on its own source frame, before it is placed on the canvas.
  /// A clip with its own [VideoSegment.chromaKey] overrides this; when neither
  /// is set, the clip falls back to [VideoRenderData.chromaKey].
  ///
  /// Since the keyed area is transparent by default, the layer below shows
  /// through — which is how you put a video behind a green screen.
  final ChromaKey? chromaKey;

  /// The layer's placement over time; see [TimelineKeyframe].
  ///
  /// When not empty, the keyframes move every clip of the layer: a
  /// keyframe's offset replaces the top-left corner of the clip's placement
  /// box ([VideoSegment.transform], else [transform], else the whole canvas),
  /// its scale grows or shrinks that box around its center, its rotation
  /// replaces the box's rotation and its opacity replaces [opacity]. The box
  /// keeps its [SegmentTransform.fit]. Their times are on the composition's
  /// timeline, like [VideoSegment.timelineStart], and need not be in order.
  ///
  /// **Default**: empty, which keeps every clip where its transform puts it.
  final List<TimelineKeyframe> keyframes;

  /// The clock [keyframes] are timed on; see [KeyframeClockPoint].
  ///
  /// When not empty, every frame is placed by the keyframes at its time on
  /// this clock instead of at its time on the composition.
  ///
  /// **Default**: empty, which times [keyframes] on the composition's
  /// timeline.
  final List<KeyframeClockPoint> keyframeClock;

  /// Converts this layer to a map for platform channel communication.
  ///
  /// Resolves each clip's input path and any chroma-key background image, so
  /// this is asynchronous.
  Future<Map<String, dynamic>> toAsyncMap() async {
    assert(
      clips.every((c) => c.transition == null),
      'Transitions are not supported within a VideoComposition layer. '
      'Remove VideoSegment.transition from composition clips, or use '
      'videoSegments when you need clip transitions.',
    );
    assert(
      clips.every((c) => c.playbackSpeed == null && !c.reverseVideo),
      'playbackSpeed and reverseVideo are not supported within a '
      'VideoComposition. Pre-render them into the source, or use '
      'videoSegments.',
    );
    return {
      'clips': await Future.wait(clips.map((clip) => clip.toAsyncMap())),
      'opacity': opacity,
      'transform': transform?.toMap(),
      'chromaKey': await chromaKey?.toAsyncMap(),
      'keyframes': sortTimelineKeyframes(
        keyframes,
      ).map((k) => k.toMap()).toList(),
      'keyframeClock': keyframeClock.map((p) => p.toMap()).toList(),
    };
  }

  /// Creates a copy with updated values.
  VideoLayer copyWith({
    List<VideoSegment>? clips,
    double? opacity,
    SegmentTransform? transform,
    ChromaKey? chromaKey,
    List<TimelineKeyframe>? keyframes,
    List<KeyframeClockPoint>? keyframeClock,
  }) {
    return VideoLayer(
      clips: clips ?? this.clips,
      opacity: opacity ?? this.opacity,
      transform: transform ?? this.transform,
      chromaKey: chromaKey ?? this.chromaKey,
      keyframes: keyframes ?? this.keyframes,
      keyframeClock: keyframeClock ?? this.keyframeClock,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'clips': clips.map((x) => x.toMap()).toList(),
      'opacity': opacity,
      'transform': transform?.toMap(),
      'chromaKey': chromaKey?.toMap(),
      'keyframes': keyframes.map((k) => k.toMap()).toList(),
      'keyframeClock': keyframeClock.map((p) => p.toMap()).toList(),
    };
  }

  factory VideoLayer.fromMap(Map<String, dynamic> map) {
    return VideoLayer(
      clips: List<VideoSegment>.from(
        (map['clips'] as List).map<VideoSegment>(
          (x) => VideoSegment.fromMap(x as Map<String, dynamic>),
        ),
      ),
      opacity: map['opacity'] != null ? safeParseDouble(map['opacity']) : 1.0,
      transform: map['transform'] != null
          ? SegmentTransform.fromMap(map['transform'] as Map<String, dynamic>)
          : null,
      chromaKey: map['chromaKey'] != null
          ? ChromaKey.fromMap(map['chromaKey'] as Map<String, dynamic>)
          : null,
      keyframes:
          (map['keyframes'] as List<dynamic>?)
              ?.map(
                (k) => TimelineKeyframe.fromMap(
                  Map<String, dynamic>.from(k as Map),
                ),
              )
              .toList() ??
          const [],
      keyframeClock: keyframeClockFromMap(map['keyframeClock']),
    );
  }

  String toJson() => json.encode(toMap());

  factory VideoLayer.fromJson(String source) =>
      VideoLayer.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() =>
      'VideoLayer(clips: $clips, opacity: $opacity, transform: $transform, '
      'chromaKey: $chromaKey, keyframes: $keyframes, '
      'keyframeClock: $keyframeClock)';

  @override
  bool operator ==(covariant VideoLayer other) {
    if (identical(this, other)) return true;

    return listEquals(other.clips, clips) &&
        other.opacity == opacity &&
        other.transform == transform &&
        other.chromaKey == chromaKey &&
        listEquals(other.keyframes, keyframes) &&
        listEquals(other.keyframeClock, keyframeClock);
  }

  @override
  int get hashCode =>
      clips.hashCode ^
      opacity.hashCode ^
      transform.hashCode ^
      chromaKey.hashCode ^
      Object.hashAll(keyframes) ^
      Object.hashAll(keyframeClock);
}
