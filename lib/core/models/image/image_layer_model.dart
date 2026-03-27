import 'editor_layer_image_model.dart';

/// A model representing a video overlay layer with timing information.
class ImageLayer {
  /// Creates a [ImageLayer] with the given [image], [startTime],
  /// and optional [endTime].
  const ImageLayer({
    required this.image,
    required this.startTime,
    this.endTime,
  });

  /// The image to overlay on the video.
  final EditorLayerImage image;

  /// The start time for the layer, relative to the start of the video.
  final Duration startTime;

  /// The end time of the layer, relative to the start of the video.
  /// If `null`, the layer will be shown until the end of the video.
  final Duration? endTime;
}
