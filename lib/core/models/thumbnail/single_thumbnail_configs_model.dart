import 'thumbnail_base_abstract.dart';

/// Position from which to extract a single thumbnail.
enum ThumbnailPosition {
  /// Extract the first frame of the video (at timestamp 0).
  first,

  /// Extract the last frame of the video (near the end of the duration).
  last,
}

/// Configuration model for extracting a single thumbnail from a video.
///
/// This convenience model allows extracting either the first or last frame
/// of a video without needing to specify exact timestamps.
///
/// For [ThumbnailPosition.first], a frame at timestamp 0 is extracted.
/// For [ThumbnailPosition.last], the video duration is resolved automatically
/// (or from [videoDuration] if provided) and a frame near the end is extracted.
///
/// Example:
/// ```dart
/// final config = SingleThumbnailConfigs(
///   video: EditorVideo.file('/path/to/video.mp4'),
///   outputSize: Size(256, 256),
///   position: ThumbnailPosition.first,
/// );
///
/// final thumbnail = await ProVideoEditor.instance.getSingleThumbnail(config);
/// ```
class SingleThumbnailConfigs extends ThumbnailBase {
  /// Creates a [SingleThumbnailConfigs] instance.
  ///
  /// [position] determines whether to extract the first or last frame.
  ///
  /// [videoDuration] can be provided to avoid an additional metadata lookup
  /// when [position] is [ThumbnailPosition.last]. If not provided,
  /// the duration will be resolved automatically.
  SingleThumbnailConfigs({
    required super.video,
    required super.outputSize,
    super.outputFormat,
    super.boxFit,
    super.id,
    super.jpegQuality,
    required this.position,
    this.videoDuration,
  });

  /// Whether to extract the first or last frame.
  final ThumbnailPosition position;

  /// Optional video duration to avoid an extra metadata lookup when
  /// extracting the last frame.
  ///
  /// If null and [position] is [ThumbnailPosition.last], the duration
  /// will be fetched automatically via [getMetadata].
  final Duration? videoDuration;

  @override
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'jpegQuality': jpegQuality,
      'boxFit': boxFit.name,
      'outputFormat': outputFormat.name,
      'outputWidth': outputSize.width.round(),
      'outputHeight': outputSize.height.round(),
      'timestamps': <int>[],
    };
  }
}
