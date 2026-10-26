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
/// clip provides its own [VideoSegment.transform], placed using [transform]. A
/// [mask] or a [shapeMask] shows its clips only within a shape, or fades them
/// out through a soft edge, and [blendMode] combines them with the layers
/// below, such as a double exposure of two clips.
class VideoLayer {
  /// Creates a [VideoLayer] from a list of [clips].
  const VideoLayer({
    required this.clips,
    this.opacity = 1.0,
    this.transform,
    this.chromaKey,
    this.mask,
    this.shapeMask,
    this.keyframes = const [],
    this.keyframeClock = const [],
    this.blendMode = LayerBlendMode.normal,
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

  /// An alpha matte that shapes every clip of this layer, such as a circle, a
  /// heart or a rectangle with rounded or soft edges.
  ///
  /// Only the matte's **alpha** counts; its colors are ignored. Each pixel of a
  /// clip keeps its own alpha times the matte's alpha there: where the matte is
  /// opaque the clip shows, where it is transparent the layers below show
  /// through (or [VideoComposition.backgroundColor] on the bottom layer), and
  /// partial alpha blends the two — which is how a feathered or gradient edge
  /// fades the clip into the track below.
  ///
  /// The matte is stretched over each clip's **own source frame**, the frame
  /// as it comes out of the decoder with its rotation metadata applied. That
  /// happens after the clip's chroma key and before the clip is placed on the
  /// canvas, so the mask moves, scales and turns with the clip — by
  /// [VideoSegment.transform] or [transform], their rotation, and [keyframes].
  /// A [SegmentFit.cover] or [SegmentFit.contain] fit then treats the masked
  /// frame like any other: `contain` shows all of the shape, while `cover` cuts
  /// off whatever of it overflows the box. Draw the matte at the clips' aspect
  /// ratio, or the stretch pulls the shape out of proportion.
  ///
  /// It combines with the rest of the layer: a pixel the chroma key removed
  /// stays removed, and [opacity] — or a keyframe's opacity — applies on top.
  ///
  /// The matte's EXIF orientation is applied, as for
  /// [ChromaKey.backgroundImage]. A matte that does not decode fails the
  /// render rather than export the clips in a shape nobody asked for.
  ///
  /// **Default**: `null`, which shows every clip whole.
  ///
  /// **Note:** Ignored on Web, Windows and Linux, which have no render
  /// pipeline.
  final EditorLayerImage? mask;

  /// A shape every clip of this layer shows through, drawn on each frame, so
  /// it can change over time on its own; see [LayerShapeMask].
  ///
  /// It is measured in fractions of each clip's own upright source frame and
  /// applied where [mask] is, after the chroma key and before the clip is
  /// placed, so it moves, scales and turns with the clip as well. Its
  /// [LayerShapeMask.keyframes] are timed like [keyframes], on [keyframeClock]
  /// when the layer has one. With [mask] as well, a pixel keeps the alpha of
  /// both.
  ///
  /// **Default**: `null`, which shows every clip whole.
  ///
  /// **Note:** Ignored on Web, Windows and Linux, which have no render
  /// pipeline.
  final LayerShapeMask? shapeMask;

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

  /// How the layer combines with the layers below it; see [LayerBlendMode].
  ///
  /// The backdrop is everything composited beneath the layer at that pixel:
  /// the layers before it in [VideoComposition.layers] over
  /// [VideoComposition.backgroundColor]. Each clip is blended as it is
  /// placed, after its chroma key and [mask], and its alpha there — what the
  /// key and the mask leave of it, times [opacity] or a keyframe's opacity —
  /// fades between the backdrop and the blended color. Where the layer has no
  /// clip, or a [SegmentFit.contain] fit leaves its box empty, the backdrop
  /// stays as it is. The layers above it draw over the result, and the
  /// composition's [VideoRenderData.imageLayers] over all of them.
  ///
  /// [LayerBlendMode.screen] over a clip recorded against black adds only its
  /// light, such as a flame or a light leak; [LayerBlendMode.multiply] or
  /// [LayerBlendMode.screen] of a portrait over a landscape makes a double
  /// exposure.
  ///
  /// **Default**: [LayerBlendMode.normal], which draws the clips over the
  /// layers below.
  ///
  /// **Note:** Ignored on Web, Windows and Linux, which have no render
  /// pipeline.
  final LayerBlendMode blendMode;

  /// Converts this layer to a map for platform channel communication.
  ///
  /// Resolves each clip's input path, any chroma-key background image and the
  /// [mask], so this is asynchronous. See [EditorLayerImage.toChannelSource]
  /// for what that means for a file-backed matte.
  ///
  /// Throws an [ArgumentError] when [mask] resolves to no bytes at all.
  Future<Map<String, dynamic>> toAsyncMap() async {
    assert(
      clips.every((c) => c.transition == null),
      'Transitions are not supported within a VideoComposition layer. '
      'Remove VideoSegment.transition from composition clips, or use '
      'videoSegments when you need clip transitions.',
    );
    assert(
      clips.every(
        (c) =>
            c.playbackSpeed == null && c.speedRamp == null && !c.reverseVideo,
      ),
      'playbackSpeed, speedRamp and reverseVideo are not supported within a '
      'VideoComposition. Pre-render them into the source, or use '
      'videoSegments.',
    );
    final mask = this.mask;
    final maskSource = mask == null
        ? null
        : await mask.toChannelSource(pathKey: 'maskPath', dataKey: 'maskData');
    // The renderers read empty bytes as "no image", which would export the
    // clips unmasked instead of failing.
    if ((maskSource?['maskData'] as Uint8List?)?.isEmpty ?? false) {
      throw ArgumentError.value(mask, 'mask', 'The mask image is empty');
    }
    return {
      'clips': await Future.wait(clips.map((clip) => clip.toAsyncMap())),
      'opacity': opacity,
      'transform': transform?.toMap(),
      'chromaKey': await chromaKey?.toAsyncMap(),
      ...?maskSource,
      'shapeMask': shapeMask?.toMap(),
      'keyframes': sortTimelineKeyframes(
        keyframes,
      ).map((k) => k.toMap()).toList(),
      'keyframeClock': keyframeClock.map((p) => p.toMap()).toList(),
      'blendMode': blendMode.name,
    };
  }

  /// Creates a copy with updated values.
  VideoLayer copyWith({
    List<VideoSegment>? clips,
    double? opacity,
    SegmentTransform? transform,
    ChromaKey? chromaKey,
    EditorLayerImage? mask,
    LayerShapeMask? shapeMask,
    List<TimelineKeyframe>? keyframes,
    List<KeyframeClockPoint>? keyframeClock,
    LayerBlendMode? blendMode,
  }) {
    return VideoLayer(
      clips: clips ?? this.clips,
      opacity: opacity ?? this.opacity,
      transform: transform ?? this.transform,
      chromaKey: chromaKey ?? this.chromaKey,
      mask: mask ?? this.mask,
      shapeMask: shapeMask ?? this.shapeMask,
      keyframes: keyframes ?? this.keyframes,
      keyframeClock: keyframeClock ?? this.keyframeClock,
      blendMode: blendMode ?? this.blendMode,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'clips': clips.map((x) => x.toMap()).toList(),
      'opacity': opacity,
      'transform': transform?.toMap(),
      'chromaKey': chromaKey?.toMap(),
      'mask': mask?.toMap(),
      'shapeMask': shapeMask?.toMap(),
      'keyframes': keyframes.map((k) => k.toMap()).toList(),
      'keyframeClock': keyframeClock.map((p) => p.toMap()).toList(),
      'blendMode': blendMode.name,
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
      mask: map['mask'] != null
          ? EditorLayerImage.fromMap(map['mask'] as Map<String, dynamic>)
          : null,
      shapeMask: map['shapeMask'] is Map
          ? LayerShapeMask.fromMap(
              Map<String, dynamic>.from(map['shapeMask'] as Map),
            )
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
      blendMode: LayerBlendMode.fromName(map['blendMode']),
    );
  }

  String toJson() => json.encode(toMap());

  factory VideoLayer.fromJson(String source) =>
      VideoLayer.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() =>
      'VideoLayer(clips: $clips, opacity: $opacity, transform: $transform, '
      'chromaKey: $chromaKey, mask: $mask, shapeMask: $shapeMask, '
      'keyframes: $keyframes, '
      'keyframeClock: $keyframeClock, blendMode: $blendMode)';

  @override
  bool operator ==(covariant VideoLayer other) {
    if (identical(this, other)) return true;

    return listEquals(other.clips, clips) &&
        other.opacity == opacity &&
        other.transform == transform &&
        other.chromaKey == chromaKey &&
        other.mask == mask &&
        other.shapeMask == shapeMask &&
        listEquals(other.keyframes, keyframes) &&
        listEquals(other.keyframeClock, keyframeClock) &&
        other.blendMode == blendMode;
  }

  @override
  int get hashCode =>
      clips.hashCode ^
      opacity.hashCode ^
      transform.hashCode ^
      chromaKey.hashCode ^
      mask.hashCode ^
      shapeMask.hashCode ^
      Object.hashAll(keyframes) ^
      Object.hashAll(keyframeClock) ^
      blendMode.hashCode;
}
