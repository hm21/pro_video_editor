// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/size_parser.dart';

/// A multi-layer video composition.
///
/// A composition stacks several [VideoLayer]s on a fixed-size canvas. Each
/// layer is a track that holds a time-ordered sequence of clips, and layers are
/// composited bottom-to-top in list order (the last layer is drawn on top).
///
/// This is the spatial counterpart to a flat list of video segments: while a
/// segment list models a single track of concatenated clips, a composition
/// models multiple tracks that can overlap in time and space (picture-in-
/// picture, side-by-side, grid, …).
///
/// **Example (picture-in-picture):**
/// ```dart
/// VideoComposition(
///   canvasSize: const Size(1080, 1920),
///   layers: [
///     VideoLayer(clips: [VideoSegment(video: mainVideo)]),
///     VideoLayer(
///       clips: [VideoSegment(video: pipVideo)],
///       transform: const SegmentTransform(
///         offset: Offset(20, 20),
///         size: Size(360, 640),
///         fit: SegmentFit.cover,
///       ),
///     ),
///   ],
/// );
/// ```
class VideoComposition {
  /// Creates a [VideoComposition] from a bottom-to-top list of [layers].
  const VideoComposition({
    required this.layers,
    this.canvasSize,
    this.backgroundColor = const Color(0xFF000000),
  }) : assert(layers.length > 0, 'A composition must contain at least 1 layer');

  /// The layers of this composition, ordered bottom-to-top.
  ///
  /// The first layer is drawn first (at the bottom), the last layer on top.
  final List<VideoLayer> layers;

  /// The output canvas size in pixels.
  ///
  /// All layers are positioned and scaled relative to this canvas. When `null`,
  /// the size is derived from the first clip of the first layer.
  final Size? canvasSize;

  /// The color used to fill areas of the canvas not covered by any layer.
  ///
  /// **Default**: opaque black.
  final Color backgroundColor;

  /// Converts this composition to a map for platform channel communication.
  ///
  /// Resolves each clip's input path, so this is asynchronous.
  Future<Map<String, dynamic>> toAsyncMap() async {
    return {
      'layers': await Future.wait(layers.map((layer) => layer.toAsyncMap())),
      'canvasWidth': canvasSize?.width,
      'canvasHeight': canvasSize?.height,
      'backgroundColor': backgroundColor.toARGB32(),
    };
  }

  /// Creates a copy with updated values.
  VideoComposition copyWith({
    List<VideoLayer>? layers,
    Size? canvasSize,
    Color? backgroundColor,
  }) {
    return VideoComposition(
      layers: layers ?? this.layers,
      canvasSize: canvasSize ?? this.canvasSize,
      backgroundColor: backgroundColor ?? this.backgroundColor,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'layers': layers.map((x) => x.toMap()).toList(),
      'canvasSize': canvasSize != null
          ? {'width': canvasSize!.width, 'height': canvasSize!.height}
          : null,
      'backgroundColor': backgroundColor.toARGB32(),
    };
  }

  factory VideoComposition.fromMap(Map<String, dynamic> map) {
    return VideoComposition(
      layers: List<VideoLayer>.from(
        (map['layers'] as List).map<VideoLayer>(
          (x) => VideoLayer.fromMap(x as Map<String, dynamic>),
        ),
      ),
      canvasSize: map['canvasSize'] != null
          ? safeParseSize(map['canvasSize'] as Map<String, dynamic>)
          : null,
      backgroundColor: map['backgroundColor'] != null
          ? Color(safeParseInt(map['backgroundColor']))
          : const Color(0xFF000000),
    );
  }

  String toJson() => json.encode(toMap());

  factory VideoComposition.fromJson(String source) =>
      VideoComposition.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() =>
      'VideoComposition(layers: $layers, '
      'canvasSize: $canvasSize, backgroundColor: $backgroundColor)';

  @override
  bool operator ==(covariant VideoComposition other) {
    if (identical(this, other)) return true;

    return listEquals(other.layers, layers) &&
        other.canvasSize == canvasSize &&
        other.backgroundColor == backgroundColor;
  }

  @override
  int get hashCode =>
      layers.hashCode ^ canvasSize.hashCode ^ backgroundColor.hashCode;
}
