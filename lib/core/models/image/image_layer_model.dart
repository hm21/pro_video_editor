// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/shared/models/time_range_mixin.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/offset_parser.dart';

import 'editor_layer_image_model.dart';
import 'layer_animation_model.dart';
import 'layer_censor_model.dart';

/// A model representing a video overlay layer with timing information.
class ImageLayer with TimeRangeMixin {
  /// Creates a [ImageLayer] with the given [image], [startTime],
  /// and optional [endTime].
  const ImageLayer({
    required this.image,
    this.startTime,
    this.endTime,
    this.offset,
    this.size,
    this.rotation = 0.0,
    this.loop = true,
    this.animationOffset = Duration.zero,
    this.animations = const [],
    this.animationStartTime,
    this.animationEndTime,
    this.censor,
  }) : assert(
         startTime == null || endTime == null || startTime < endTime,
         'startTime must be before endTime',
       ),
       assert(
         animationOffset >= Duration.zero,
         'animationOffset must not be negative',
       ),
       assert(
         animationStartTime == null ||
             animationEndTime == null ||
             animationStartTime < animationEndTime,
         'animationStartTime must be before animationEndTime',
       );

  /// The image to overlay on the video.
  ///
  /// Animated formats (e.g. GIF) are detected automatically and played back
  /// frame by frame for the time the layer is visible — see [loop]. Static
  /// images are drawn unchanged.
  final EditorLayerImage image;

  @override
  final Duration? startTime;

  @override
  final Duration? endTime;

  /// Position offset from the top-left corner of the video frame, in pixels.
  ///
  /// [Offset.dx] is the horizontal offset from the left edge.
  /// [Offset.dy] is the vertical offset from the top edge.
  ///
  /// When `null`, the image is stretched to fill the entire video frame.
  /// When set to a specific value (e.g., [Offset.zero]), the image is
  /// placed at that position at its original size.
  ///
  /// When the video segments differ in resolution, the video frame is the one
  /// they are composited into: the first segment's size, replaced by each
  /// later segment that is wider or taller. Every segment is scaled to fit
  /// inside it and the layer is placed from the scaled segment's top-left
  /// corner, so a layer keeps its place and size on segments of one shape.
  final Offset? offset;

  /// The display size of the image layer, in pixels of the same frame as
  /// [offset].
  ///
  /// [Size.width] is the target width of the image.
  /// [Size.height] is the target height of the image.
  ///
  /// When `null`, the image is used at its original size (or stretched to
  /// fill the frame when [offset] is also `null`).
  final Size? size;

  /// Clockwise rotation applied to the image layer, in **radians**.
  ///
  /// The image is rotated around its own center, so [offset] and [size] still
  /// describe the unrotated layout box. This matches Flutter's
  /// [Transform.rotate] convention, which makes it possible to forward a
  /// `pro_image_editor` layer rotation directly.
  ///
  /// **Default**: `0.0` (no rotation).
  final double rotation;

  /// Whether an animated [image] (e.g. GIF) repeats while the layer is visible.
  ///
  /// - `true` (default): the animation loops for the layer's whole time range.
  /// - `false`: the animation plays once and then holds its last frame until
  ///   the layer disappears.
  ///
  /// Has no effect on static images.
  final bool loop;

  /// How far into an animated [image] (e.g. GIF) playback begins when the
  /// layer appears at [startTime].
  ///
  /// By default an animated layer starts on its first frame. Set this to
  /// continue one animation across several layers: a layer that picks up
  /// where `previous` left off passes
  ///
  /// ```dart
  /// previous.animationOffset +
  ///     (previous.endTime! - (previous.startTime ?? Duration.zero))
  /// ```
  ///
  /// The offset counts toward [loop], so it wraps around a looping image and
  /// lands on the last frame of one that does not loop.
  ///
  /// Has no effect on static images.
  ///
  /// **Default**: [Duration.zero].
  final Duration animationOffset;

  /// Animations to apply to this layer (e.g. fade, slide, scale).
  ///
  /// Multiple animations can be combined. Each animation specifies its
  /// [LayerAnimation.phase] (in or out), [LayerAnimation.duration],
  /// and optional [LayerAnimation.curve].
  final List<LayerAnimation> animations;

  /// Where the [animations] count from, when that is not [startTime].
  ///
  /// An [AnimationPhase.animateIn] plays from here and an
  /// [AnimationPhase.loop] starts its first cycle here; the layer itself still
  /// shows only from [startTime] to [endTime]. Set it, together with
  /// [animationEndTime], to keep one set of animations running across several
  /// layers that each show the content for part of the time, such as the
  /// steps of a text that types itself out or the words of a karaoke caption
  /// lighting up one by one: every part carries the same animations and the
  /// same range, so a fade in carries on over the first parts and a wiggle
  /// does not restart at each one.
  ///
  /// **Default**: `null`, which counts from [startTime].
  final Duration? animationStartTime;

  /// Where the [animations] end, when that is not [endTime]: an
  /// [AnimationPhase.animateOut] finishes here. See [animationStartTime].
  ///
  /// **Default**: `null`, which ends at [endTime].
  final Duration? animationEndTime;

  /// Blurs or pixelates the picture beneath the layer instead of drawing
  /// [image], which then only marks the area to hide. See [LayerCensor].
  ///
  /// The area takes its place, size, [rotation], time range and [animations]
  /// from the layer exactly as [image] would be drawn, and a fade animation
  /// fades the censor in and out.
  ///
  /// **Default**: `null`, which draws [image].
  final LayerCensor? censor;

  ImageLayer copyWith({
    EditorLayerImage? image,
    Duration? startTime,
    Duration? endTime,
    Offset? offset,
    Size? size,
    double? rotation,
    bool? loop,
    Duration? animationOffset,
    List<LayerAnimation>? animations,
    Duration? animationStartTime,
    Duration? animationEndTime,
    LayerCensor? censor,
  }) {
    return ImageLayer(
      image: image ?? this.image,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      offset: offset ?? this.offset,
      size: size ?? this.size,
      rotation: rotation ?? this.rotation,
      loop: loop ?? this.loop,
      animationOffset: animationOffset ?? this.animationOffset,
      animations: animations ?? this.animations,
      animationStartTime: animationStartTime ?? this.animationStartTime,
      animationEndTime: animationEndTime ?? this.animationEndTime,
      censor: censor ?? this.censor,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'image': image.toMap(),
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
      'offset': offset != null ? {'dx': offset!.dx, 'dy': offset!.dy} : null,
      'size': size != null
          ? {'width': size!.width, 'height': size!.height}
          : null,
      'rotation': rotation,
      'loop': loop,
      'animationOffset': animationOffset.inMicroseconds,
      'animations': animations.map((a) => a.toMap()).toList(),
      'animationStartTime': animationStartTime?.inMicroseconds,
      'animationEndTime': animationEndTime?.inMicroseconds,
      'censor': censor?.toMap(),
    };
  }

  factory ImageLayer.fromMap(Map<String, dynamic> map) {
    return ImageLayer(
      image: EditorLayerImage.fromMap(map['image'] as Map<String, dynamic>),
      startTime: map['startTime'] != null
          ? Duration(microseconds: safeParseInt(map['startTime']))
          : null,
      endTime: map['endTime'] != null
          ? Duration(microseconds: safeParseInt(map['endTime']))
          : null,
      offset: map['offset'] != null
          ? safeParseOffset(map['offset'] as Map<String, dynamic>)
          : null,
      size: map['size'] != null
          ? Size(
              safeParseDouble((map['size'] as Map<String, dynamic>)['width']),
              safeParseDouble((map['size'] as Map<String, dynamic>)['height']),
            )
          : null,
      rotation: map['rotation'] != null
          ? safeParseDouble(map['rotation'])
          : 0.0,
      loop: map['loop'] as bool? ?? true,
      animationOffset: map['animationOffset'] != null
          ? Duration(microseconds: safeParseInt(map['animationOffset']))
          : Duration.zero,
      animations:
          (map['animations'] as List<dynamic>?)
              ?.map((a) => LayerAnimation.fromMap(a as Map<String, dynamic>))
              .toList() ??
          const [],
      animationStartTime: map['animationStartTime'] != null
          ? Duration(microseconds: safeParseInt(map['animationStartTime']))
          : null,
      animationEndTime: map['animationEndTime'] != null
          ? Duration(microseconds: safeParseInt(map['animationEndTime']))
          : null,
      censor: map['censor'] != null
          ? LayerCensor.fromMap(map['censor'] as Map<String, dynamic>)
          : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory ImageLayer.fromJson(String source) =>
      ImageLayer.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() {
    return 'ImageLayer('
        'image: $image, '
        'startTime: $startTime, '
        'endTime: $endTime, '
        'offset: $offset, '
        'size: $size, '
        'rotation: $rotation, '
        'loop: $loop, '
        'animationOffset: $animationOffset, '
        'animations: $animations, '
        'animationStartTime: $animationStartTime, '
        'animationEndTime: $animationEndTime, '
        'censor: $censor'
        ')';
  }

  @override
  bool operator ==(covariant ImageLayer other) {
    if (identical(this, other)) return true;

    return other.image == image &&
        other.startTime == startTime &&
        other.endTime == endTime &&
        other.offset == offset &&
        other.size == size &&
        other.rotation == rotation &&
        other.loop == loop &&
        other.animationOffset == animationOffset &&
        listEquals(other.animations, animations) &&
        other.animationStartTime == animationStartTime &&
        other.animationEndTime == animationEndTime &&
        other.censor == censor;
  }

  @override
  int get hashCode {
    return image.hashCode ^
        startTime.hashCode ^
        endTime.hashCode ^
        offset.hashCode ^
        size.hashCode ^
        rotation.hashCode ^
        loop.hashCode ^
        animationOffset.hashCode ^
        animations.hashCode ^
        animationStartTime.hashCode ^
        animationEndTime.hashCode ^
        censor.hashCode;
  }
}
