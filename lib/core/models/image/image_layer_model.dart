// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/shared/models/time_range_mixin.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

import 'editor_layer_image_model.dart';
import 'layer_animation_model.dart';

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
    this.animations = const [],
  }) : assert(
         startTime == null || endTime == null || startTime < endTime,
         'startTime must be before endTime',
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
  final Offset? offset;

  /// The display size of the image layer, in pixels.
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

  /// Animations to apply to this layer (e.g. fade, slide, scale).
  ///
  /// Multiple animations can be combined. Each animation specifies its
  /// [LayerAnimation.phase] (in or out), [LayerAnimation.duration],
  /// and optional [LayerAnimation.curve].
  final List<LayerAnimation> animations;

  ImageLayer copyWith({
    EditorLayerImage? image,
    Duration? startTime,
    Duration? endTime,
    Offset? offset,
    Size? size,
    double? rotation,
    bool? loop,
    List<LayerAnimation>? animations,
  }) {
    return ImageLayer(
      image: image ?? this.image,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      offset: offset ?? this.offset,
      size: size ?? this.size,
      rotation: rotation ?? this.rotation,
      loop: loop ?? this.loop,
      animations: animations ?? this.animations,
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
      'animations': animations.map((a) => a.toMap()).toList(),
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
          ? Offset(
              safeParseDouble((map['offset'] as Map<String, dynamic>)['dx']),
              safeParseDouble((map['offset'] as Map<String, dynamic>)['dy']),
            )
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
      animations:
          (map['animations'] as List<dynamic>?)
              ?.map((a) => LayerAnimation.fromMap(a as Map<String, dynamic>))
              .toList() ??
          const [],
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
        'animations: $animations'
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
        listEquals(other.animations, animations);
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
        animations.hashCode;
  }
}
