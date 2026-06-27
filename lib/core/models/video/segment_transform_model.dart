// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';
import 'dart:ui';

import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';

/// Defines how a video segment's source frame is scaled into its target
/// [SegmentTransform.size].
enum SegmentFit {
  /// Stretch the source to exactly fill the target size, ignoring the source
  /// aspect ratio.
  fill,

  /// Scale the source to fit entirely within the target size, preserving the
  /// aspect ratio. May leave empty space (letterboxing).
  contain,

  /// Scale the source to completely cover the target size, preserving the
  /// aspect ratio. May crop parts of the source.
  cover,
}

/// Describes how a video segment is positioned and scaled within the
/// composition canvas.
///
/// A transform can be attached to an individual [VideoSegment] or used as the
/// default placement for all clips on a [VideoLayer]. A segment-level transform
/// overrides the layer-level transform.
///
/// When a segment has no transform (neither on the segment nor on its layer),
/// it is stretched to fill the entire canvas.
class SegmentTransform {
  /// Creates a [SegmentTransform].
  const SegmentTransform({
    this.offset,
    this.size,
    this.fit = SegmentFit.cover,
  });

  /// Position of the segment's top-left corner within the canvas, in pixels.
  ///
  /// When `null`, the segment is placed at the top-left corner
  /// ([Offset.zero]).
  final Offset? offset;

  /// Target size of the segment within the canvas, in pixels.
  ///
  /// When `null`, the segment keeps its source size. When both [offset] and
  /// [size] are `null`, the segment is stretched to fill the entire canvas.
  final Size? size;

  /// How the source frame is scaled into [size].
  ///
  /// Only relevant when [size] is set. **Default**: [SegmentFit.cover].
  final SegmentFit fit;

  /// Creates a copy with updated values.
  SegmentTransform copyWith({
    Offset? offset,
    Size? size,
    SegmentFit? fit,
  }) {
    return SegmentTransform(
      offset: offset ?? this.offset,
      size: size ?? this.size,
      fit: fit ?? this.fit,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'offset': offset != null ? {'dx': offset!.dx, 'dy': offset!.dy} : null,
      'size':
          size != null ? {'width': size!.width, 'height': size!.height} : null,
      'fit': fit.name,
    };
  }

  factory SegmentTransform.fromMap(Map<String, dynamic> map) {
    return SegmentTransform(
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
      fit: map['fit'] != null
          ? SegmentFit.values.byName(map['fit'] as String)
          : SegmentFit.cover,
    );
  }

  String toJson() => json.encode(toMap());

  factory SegmentTransform.fromJson(String source) =>
      SegmentTransform.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() =>
      'SegmentTransform(offset: $offset, size: $size, fit: $fit)';

  @override
  bool operator ==(covariant SegmentTransform other) {
    if (identical(this, other)) return true;

    return other.offset == offset && other.size == size && other.fit == fit;
  }

  @override
  int get hashCode => offset.hashCode ^ size.hashCode ^ fit.hashCode;
}
