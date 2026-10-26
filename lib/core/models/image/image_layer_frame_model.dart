import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

import 'editor_layer_image_model.dart';

/// One image of an [ImageLayer.frames] sequence and how long it shows.
///
/// The frames of a sequence play one after the other like the frames of an
/// animated GIF, so a layer whose picture changes over time — a running
/// timer, a counter, text that types itself out — is drawn by one overlay
/// that swaps its image, instead of one layer for every image.
@immutable
class ImageLayerFrame {
  /// Creates a frame showing [image] for [duration].
  const ImageLayerFrame({required this.image, required this.duration})
    : assert(duration > Duration.zero, 'A frame must show for some time');

  /// Creates an [ImageLayerFrame] from a map written by [toMap].
  factory ImageLayerFrame.fromMap(Map<String, dynamic> map) {
    return ImageLayerFrame(
      image: EditorLayerImage.fromMap(
        Map<String, dynamic>.from(map['image'] as Map),
      ),
      duration: Duration(microseconds: safeParseInt(map['durationUs'])),
    );
  }

  /// The image to show. Every frame of a sequence is drawn into the same
  /// box, so give them all the same pixel size.
  final EditorLayerImage image;

  /// How long the frame shows before the next one.
  final Duration duration;

  /// Converts this frame to a map.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'image': image.toMap(),
    'durationUs': duration.inMicroseconds,
  };

  /// This frame as the native renderers read it: its image as a path or as
  /// bytes (see [EditorLayerImage.toChannelSource]) and its duration.
  Future<Map<String, dynamic>> toChannelMap() async => <String, dynamic>{
    ...await image.toChannelSource(pathKey: 'imagePath', dataKey: 'imageData'),
    'durationUs': duration.inMicroseconds,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ImageLayerFrame &&
        other.image == image &&
        other.duration == duration;
  }

  @override
  int get hashCode => Object.hash(image, duration);

  @override
  String toString() => 'ImageLayerFrame(image: $image, duration: $duration)';
}
