// ignore_for_file: sort_constructors_first
import 'dart:convert';
import 'dart:ui' show Size;

import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

/// Describes how a single frame is mapped onto the output video size when its
/// aspect ratio differs from the target resolution.
enum StopMotionFit {
  /// Scales the frame to fit entirely inside the output, preserving aspect
  /// ratio. Remaining area is filled with a black background (letterbox).
  contain,

  /// Scales the frame to fill the entire output, preserving aspect ratio.
  /// Parts that overflow the output bounds are cropped.
  cover,

  /// Stretches the frame to exactly match the output size, ignoring the
  /// original aspect ratio.
  stretch,
}

/// A single still image used as one frame of a stop-motion video.
///
/// Each frame is held on screen for a fixed duration. If [duration] is not
/// provided, the default frame duration derived from
/// [StopMotionRenderData.frameRate] is used.
class StopMotionFrame {
  /// Creates a [StopMotionFrame] from the given [image] and optional
  /// [duration].
  const StopMotionFrame({required this.image, this.duration})
    : assert(
        duration == null || duration > Duration.zero,
        '[duration] must be greater than zero',
      );

  /// The image source for this frame.
  ///
  /// Supports images from in-memory bytes, file system, network, or asset
  /// bundle via [EditorLayerImage].
  ///
  /// Prefer [EditorLayerImage.file] for long sequences: a file-backed frame is
  /// handed to the native side as a path and opened one frame at a time, while
  /// every other source has to travel as bytes — and a few hundred photos of
  /// bytes at once is more than Android's managed heap will hold.
  final EditorLayerImage image;

  /// Optional time this frame is held on screen.
  ///
  /// If `null`, the default frame duration (`1 / frameRate`) is used.
  final Duration? duration;

  /// Converts this frame to a map for platform channel communication.
  ///
  /// A file-backed frame travels as its path (`imagePath`) and is left on disk
  /// for the native side to open when it encodes that frame. Any other source
  /// resolves to bytes (`imageData`) via [EditorLayerImage.safeByteArray].
  Future<Map<String, dynamic>> toAsyncMap() async {
    final file = image.file;
    return {
      if (file != null)
        'imagePath': file.path
      else
        'imageData': await image.safeByteArray(),
      'durationUs': duration?.inMicroseconds,
    };
  }

  /// Creates a copy with updated values.
  StopMotionFrame copyWith({EditorLayerImage? image, Duration? duration}) {
    return StopMotionFrame(
      image: image ?? this.image,
      duration: duration ?? this.duration,
    );
  }

  /// Converts this frame into a serializable [Map].
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'image': image.toMap(),
      'durationUs': duration?.inMicroseconds,
    };
  }

  /// Creates a [StopMotionFrame] from a [Map] representation.
  factory StopMotionFrame.fromMap(Map<String, dynamic> map) {
    return StopMotionFrame(
      image: EditorLayerImage.fromMap(map['image'] as Map<String, dynamic>),
      duration: map['durationUs'] != null
          ? Duration(microseconds: safeParseInt(map['durationUs']))
          : null,
    );
  }

  @override
  bool operator ==(covariant StopMotionFrame other) {
    if (identical(this, other)) return true;

    return other.image == image && other.duration == duration;
  }

  @override
  int get hashCode => image.hashCode ^ duration.hashCode;

  @override
  String toString() => 'StopMotionFrame(image: $image, duration: $duration)';
}

/// A model describing settings for rendering a stop-motion video from a
/// sequence of still images.
///
/// Each image in [frames] is held on screen for a fixed duration and the frames
/// are encoded into a single video, producing the characteristic choppy
/// stop-motion look.
///
/// **Audio:** The rendered output is silent. To add background music or other
/// audio, pass the resulting video through [ProVideoEditor.renderVideo] using
/// `audioTracks`.
class StopMotionRenderData {
  /// Creates a [StopMotionRenderData] with the given parameters.
  StopMotionRenderData({
    String? id,
    required this.frames,
    this.frameRate = 12,
    this.resolution,
    this.fit = StopMotionFit.contain,
    this.outputFormat = VideoOutputFormat.mp4,
    this.qualityConfig,
    this.bitrate,
  }) : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
       assert(frames.isNotEmpty, 'frames must not be empty'),
       assert(frameRate > 0, '[frameRate] must be greater than 0'),
       assert(
         bitrate == null || bitrate > 0,
         '[bitrate] must be greater than 0',
       );

  /// Creates a [StopMotionRenderData] with a predefined quality preset.
  ///
  /// The preset provides the [bitrate] and, when [resolution] is not given,
  /// the target [resolution] as well.
  factory StopMotionRenderData.withQualityPreset({
    String? id,
    required List<StopMotionFrame> frames,
    required VideoQualityPreset qualityPreset,
    double frameRate = 12,
    Size? resolution,
    StopMotionFit fit = StopMotionFit.contain,
    VideoOutputFormat outputFormat = VideoOutputFormat.mp4,
    int? bitrateOverride,
  }) {
    final qualityConfig = VideoQualityConfig.fromPreset(qualityPreset);

    return StopMotionRenderData(
      id: id,
      frames: frames,
      frameRate: frameRate,
      resolution: resolution ?? qualityConfig.resolution,
      fit: fit,
      outputFormat: outputFormat,
      qualityConfig: qualityConfig,
      bitrate: bitrateOverride ?? qualityConfig.bitrate,
    );
  }

  /// Unique ID for the task, useful when running multiple tasks at once.
  final String id;

  /// The ordered list of still images to encode into the video.
  ///
  /// Must contain at least one frame.
  final List<StopMotionFrame> frames;

  /// Default number of frames shown per second.
  ///
  /// Determines the default duration of each frame (`1 / frameRate`) unless a
  /// frame overrides it via [StopMotionFrame.duration].
  ///
  /// **Default**: `12`
  final double frameRate;

  /// The target output resolution (width × height).
  ///
  /// If `null`, the pixel size of the first frame is used (rounded to even
  /// values for codec compatibility).
  final Size? resolution;

  /// How each frame is mapped onto the output resolution when aspect ratios
  /// differ.
  ///
  /// **Default**: [StopMotionFit.contain]
  final StopMotionFit fit;

  /// The target format for the exported video.
  final VideoOutputFormat outputFormat;

  /// Optional quality configuration providing [bitrate] and [resolution].
  ///
  /// Explicit [bitrate] and [resolution] take precedence over this config.
  final VideoQualityConfig? qualityConfig;

  /// The bitrate of the video in bits per second.
  ///
  /// If `null`, the [qualityConfig] bitrate is used, otherwise a native
  /// default is applied.
  final int? bitrate;

  /// Returns a [Stream] of [ProgressModel] updates for this task's [id].
  Stream<ProgressModel> get progressStream {
    return ProVideoEditor.instance.progressStreamById(id);
  }

  /// Converts the model into a serializable map for platform channel
  /// communication.
  Future<Map<String, dynamic>> toAsyncMap() async {
    final frameMaps = await Future.wait(frames.map((f) => f.toAsyncMap()));
    final effectiveResolution = resolution ?? qualityConfig?.resolution;

    return {
      'id': id,
      'frames': frameMaps,
      'frameRate': frameRate,
      'width': effectiveResolution?.width.round(),
      'height': effectiveResolution?.height.round(),
      'fit': fit.name,
      'outputFormat': outputFormat.name,
      'bitrate': bitrate ?? qualityConfig?.bitrate,
    };
  }

  /// Creates a copy with updated values.
  StopMotionRenderData copyWith({
    String? id,
    List<StopMotionFrame>? frames,
    double? frameRate,
    Size? resolution,
    StopMotionFit? fit,
    VideoOutputFormat? outputFormat,
    VideoQualityConfig? qualityConfig,
    int? bitrate,
  }) {
    return StopMotionRenderData(
      id: id ?? this.id,
      frames: frames ?? this.frames,
      frameRate: frameRate ?? this.frameRate,
      resolution: resolution ?? this.resolution,
      fit: fit ?? this.fit,
      outputFormat: outputFormat ?? this.outputFormat,
      qualityConfig: qualityConfig ?? this.qualityConfig,
      bitrate: bitrate ?? this.bitrate,
    );
  }

  /// Converts this model into a serializable [Map].
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'frames': frames.map((x) => x.toMap()).toList(),
      'frameRate': frameRate,
      'width': resolution?.width,
      'height': resolution?.height,
      'fit': fit.name,
      'outputFormat': outputFormat.name,
      'qualityConfig': qualityConfig?.toMap(),
      'bitrate': bitrate,
    };
  }

  /// Creates a [StopMotionRenderData] from a [Map] representation.
  factory StopMotionRenderData.fromMap(Map<String, dynamic> map) {
    final width = tryParseDouble(map['width']);
    final height = tryParseDouble(map['height']);

    return StopMotionRenderData(
      id: map['id'] as String?,
      frames: List<StopMotionFrame>.from(
        (map['frames'] as List).map<StopMotionFrame>(
          (x) => StopMotionFrame.fromMap(x as Map<String, dynamic>),
        ),
      ),
      frameRate: tryParseDouble(map['frameRate']) ?? 12,
      resolution: width != null && height != null ? Size(width, height) : null,
      fit: map['fit'] != null
          ? StopMotionFit.values.byName(map['fit'] as String)
          : StopMotionFit.contain,
      outputFormat: VideoOutputFormat.values.byName(
        map['outputFormat'] as String,
      ),
      qualityConfig: map['qualityConfig'] != null
          ? VideoQualityConfig.fromMap(
              map['qualityConfig'] as Map<String, dynamic>,
            )
          : null,
      bitrate: map['bitrate'] != null ? safeParseInt(map['bitrate']) : null,
    );
  }

  /// Encodes this model as a JSON string.
  String toJson() => json.encode(toMap());

  /// Creates a [StopMotionRenderData] from a JSON string.
  factory StopMotionRenderData.fromJson(String source) =>
      StopMotionRenderData.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() {
    return 'StopMotionRenderData(id: $id, '
        'frames: ${frames.length}, '
        'frameRate: $frameRate, '
        'resolution: $resolution, '
        'fit: $fit, '
        'outputFormat: $outputFormat, '
        'qualityConfig: $qualityConfig, '
        'bitrate: $bitrate)';
  }
}
