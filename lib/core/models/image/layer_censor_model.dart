import 'dart:convert';

import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';

/// How a censor [ImageLayer] hides the picture beneath it.
enum LayerCensorType {
  /// A Gaussian blur.
  blur,

  /// Square blocks of one color each.
  pixelate,
}

/// Turns an [ImageLayer] into an area that blurs or pixelates the picture
/// beneath it, e.g. to hide a face, a license plate or a message on a screen.
///
/// The layer's image is not drawn. Its alpha channel is a mask: where the
/// image is opaque the picture is replaced by its blurred or pixelated
/// version, where it is transparent the picture stays as it is, and partial
/// alpha blends the two, so a soft or anti-aliased edge fades in. Draw the
/// shape of the area in any opaque color.
///
/// The picture is everything beneath the layer: the video with its
/// [VideoRenderData.effects], [VideoRenderData.colorFilters] and
/// [VideoRenderData.blur], and every image layer that comes before it in
/// [VideoRenderData.imageLayers]. Image layers after it draw on top of the
/// hidden area as usual.
///
/// ```dart
/// ImageLayer(
///   image: EditorLayerImage.memory(ovalMaskPng),
///   offset: const Offset(320, 540),
///   size: const Size(400, 480),
///   censor: const LayerCensor.blur(sigma: 40),
///   startTime: const Duration(seconds: 1),
///   endTime: const Duration(seconds: 4),
/// );
/// ```
class LayerCensor {
  /// Creates a censor of [type] with the given [strength].
  const LayerCensor({required this.type, required this.strength})
    : assert(strength > 0, 'strength must be greater than 0');

  /// Hides the area behind a Gaussian blur with the standard deviation
  /// [sigma].
  const LayerCensor.blur({double sigma = 24})
    : this(type: LayerCensorType.blur, strength: sigma);

  /// Hides the area behind square blocks with an edge length of [blockSize].
  const LayerCensor.pixelate({double blockSize = 32})
    : this(type: LayerCensorType.pixelate, strength: blockSize);

  /// Creates a censor from [toMap]'s output.
  ///
  /// An unknown [type] name throws an [ArgumentError]. A missing or
  /// non-positive strength falls back to the type's default.
  factory LayerCensor.fromMap(Map<String, dynamic> map) {
    final type = LayerCensorType.values.byName(map['type'] as String);
    final strength = tryParseDouble(map['strength']);
    if (strength != null && strength > 0) {
      return LayerCensor(type: type, strength: strength);
    }
    return switch (type) {
      LayerCensorType.blur => const LayerCensor.blur(),
      LayerCensorType.pixelate => const LayerCensor.pixelate(),
    };
  }

  /// Creates a censor from [toJson]'s output.
  factory LayerCensor.fromJson(String source) =>
      LayerCensor.fromMap(json.decode(source) as Map<String, dynamic>);

  /// How the area is hidden.
  final LayerCensorType type;

  /// How strongly the area is hidden, in pixels of the frame
  /// [ImageLayer.offset] and [ImageLayer.size] are measured in.
  ///
  /// The standard deviation of the blur for [LayerCensorType.blur], and the
  /// edge length of a block for [LayerCensorType.pixelate], rounded to whole
  /// pixels. The blocks start at the layer's top-left corner (the corner of
  /// its bounding box when it is rotated), so the area begins on whole blocks.
  final double strength;

  /// Returns a copy with the given fields replaced.
  LayerCensor copyWith({LayerCensorType? type, double? strength}) {
    return LayerCensor(
      type: type ?? this.type,
      strength: strength ?? this.strength,
    );
  }

  /// Converts the censor into a map, for saving it and for the native
  /// renderers.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{'type': type.name, 'strength': strength};
  }

  /// Converts the censor into JSON.
  String toJson() => json.encode(toMap());

  @override
  bool operator ==(Object other) =>
      other is LayerCensor && other.type == type && other.strength == strength;

  @override
  int get hashCode => Object.hash(type, strength);

  @override
  String toString() => 'LayerCensor(type: ${type.name}, strength: $strength)';
}
