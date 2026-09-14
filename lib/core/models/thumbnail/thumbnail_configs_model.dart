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
    this.maxParallelDecoders,
  }) : assert(
         maxParallelDecoders == null || maxParallelDecoders >= 1,
         'maxParallelDecoders must be at least 1',
       );

  /// A list of timestamps to capture thumbnails from.
  final List<Duration> timestamps;

  /// Upper bound of hardware decoder sessions the extraction may run at once.
  ///
  /// Android decodes the requested timestamps in up to three parallel forward
  /// passes, which is fastest when the decoder pool is otherwise idle. A caller
  /// whose thumbnails share that pool with a live player — a timeline strip
  /// next to a preview — passes `1` so the extraction never holds more than one
  /// session and cannot starve playback. `null` keeps the platform default.
  ///
  /// Only Android has parallel decoder sessions; the other platforms ignore
  /// the value.
  final int? maxParallelDecoders;

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
      if (maxParallelDecoders != null)
        'maxParallelDecoders': maxParallelDecoders,
    };
  }
}
