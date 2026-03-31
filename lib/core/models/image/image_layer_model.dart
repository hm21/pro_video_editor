// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';
import 'dart:ui';

import 'package:pro_video_editor/shared/models/time_range_mixin.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

import 'editor_layer_image_model.dart';

/// A model representing a video overlay layer with timing information.
class ImageLayer with TimeRangeMixin {
  /// Creates a [ImageLayer] with the given [image], [startTime],
  /// and optional [endTime].
  const ImageLayer({
    required this.image,
    this.startTime,
    this.endTime,
    this.offset,
  }) : assert(
          startTime == null || endTime == null || startTime < endTime,
          'startTime must be before endTime',
        );

  /// The image to overlay on the video.
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

  ImageLayer copyWith({
    EditorLayerImage? image,
    Duration? startTime,
    Duration? endTime,
    Offset? offset,
  }) {
    return ImageLayer(
      image: image ?? this.image,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      offset: offset ?? this.offset,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'image': image.toMap(),
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
      'offset': offset != null ? {'dx': offset!.dx, 'dy': offset!.dy} : null,
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
    );
  }

  String toJson() => json.encode(toMap());

  factory ImageLayer.fromJson(String source) =>
      ImageLayer.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() {
    return 'ImageLayer(image: $image, startTime: $startTime, '
        'endTime: $endTime, offset: $offset)';
  }

  @override
  bool operator ==(covariant ImageLayer other) {
    if (identical(this, other)) return true;

    return other.image == image &&
        other.startTime == startTime &&
        other.endTime == endTime &&
        other.offset == offset;
  }

  @override
  int get hashCode {
    return image.hashCode ^
        startTime.hashCode ^
        endTime.hashCode ^
        offset.hashCode;
  }
}
