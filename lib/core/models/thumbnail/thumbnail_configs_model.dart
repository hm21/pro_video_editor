import 'thumbnail_base_abstract.dart';

/// Configuration model for generating video thumbnails.
///
/// Defines the video source, output size, desired timestamps,
/// and thumbnail rendering options.
class ThumbnailConfigs extends ThumbnailBase {
  /// Creates a [ThumbnailConfigs] instance with the given parameters.
  ///
  /// Requires a video source, output size, and at least one timestamp.
  ThumbnailConfigs({
    required super.video,
    required super.outputSize,
    super.outputFormat,
    super.boxFit,
    super.id,
    super.jpegQuality,
    required this.timestamps,
  });

  /// A list of timestamps to capture thumbnails from.
  final List<Duration> timestamps;

  @override
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'jpegQuality': jpegQuality,
      'boxFit': boxFit.name,
      'outputFormat': outputFormat.name,
      'outputWidth': outputSize.width.round(),
      'outputHeight': outputSize.height.round(),
      'timestamps': timestamps
          .map((timestamp) => timestamp.inMicroseconds)
          .toList(),
    };
  }
}
