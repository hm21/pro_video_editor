import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// A model describing settings for rendering or exporting a video.
///
/// Includes input video data (single video or multiple clips), optional
/// overlays, transformations, color filters, audio options, playback settings,
/// and output format.
class VideoRenderData {
  /// Creates a [VideoRenderData] with the given parameters.
  ///
  /// **Important:** You must provide either [video] OR [videoSegments], but not
  /// both.
  /// - Use [video] for a single video with optional [startTime] and [endTime]
  /// - Use [videoSegments] for concatenating multiple videos, each with their
  ///   own trim settings
  VideoRenderData({
    this.outputFormat = VideoOutputFormat.mp4,
    this.video,
    this.videoSegments,
    this.imageBytes,
    this.imageLayers = const [],
    this.transform,
    this.enableAudio = true,
    this.playbackSpeed,
    this.startTime,
    this.endTime,
    this.blur,
    this.bitrate,
    this.colorMatrixList = const [],
    this.qualityConfig,
    this.customAudioPath,
    this.customAudioStartTime,
    this.originalAudioVolume,
    this.customAudioVolume,
    this.shouldOptimizeForNetworkUse = false,
    this.imageBytesWithCropping = false,
    this.loopCustomAudio = true,
    String? id,
  })  : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        assert(
          (video != null) != (videoSegments != null),
          'You must provide either video OR videoSegments, but not both',
        ),
        assert(
          videoSegments == null || videoSegments.isNotEmpty,
          'videoSegments must not be empty if provided',
        ),
        assert(
          startTime == null || endTime == null || startTime < endTime,
          'startTime must be before endTime',
        ),
        assert(
          blur == null || blur >= 0,
          '[blur] must be greater than or equal to 0',
        ),
        assert(
          playbackSpeed == null || playbackSpeed > 0,
          '[playbackSpeed] must be greater than 0',
        ),
        assert(
          bitrate == null || bitrate > 0,
          '[bitrate] must be greater than 0',
        ),
        assert(
          originalAudioVolume == null || originalAudioVolume >= 0,
          '[originalAudioVolume] must be greater than or equal to 0',
        ),
        assert(
          customAudioVolume == null || customAudioVolume >= 0,
          '[customAudioVolume] must be greater than or equal to 0',
        );

  /// Creates a [VideoRenderData] with a predefined quality preset.
  ///
  /// This factory constructor simplifies video export by providing common
  /// quality configurations. The preset automatically sets the appropriate
  /// bitrate and resolution.
  ///
  /// Example:
  /// ```dart
  /// var model = VideoRenderData.withQualityPreset(
  ///   video: EditorVideo.asset('assets/my-video.mp4'),
  ///   qualityPreset: VideoQualityPreset.p1080,
  ///   outputFormat: VideoOutputFormat.mp4,
  /// );
  /// ```
  ///
  /// You can override the preset's resolution by providing a custom
  /// [transform] with scale or crop settings. The bitrate from the preset
  /// will still be used unless explicitly overridden with [bitrateOverride].
  factory VideoRenderData.withQualityPreset({
    required EditorVideo video,
    required VideoQualityPreset qualityPreset,
    VideoOutputFormat outputFormat = VideoOutputFormat.mp4,
    Uint8List? imageBytes,
    List<ImageLayer> imageLayers = const [],
    ExportTransform? transform,
    bool enableAudio = true,
    double? playbackSpeed,
    Duration? startTime,
    Duration? endTime,
    double? blur,
    int? bitrateOverride,
    List<List<double>> colorMatrixList = const [],
    String? customAudioPath,
    Duration? customAudioStartTime,
    double? originalAudioVolume,
    double? customAudioVolume,
    bool shouldOptimizeForNetworkUse = false,
    bool imageBytesWithCropping = false,
    bool loopCustomAudio = true,
    String? id,
  }) {
    final qualityConfig = VideoQualityConfig.fromPreset(qualityPreset);

    return VideoRenderData(
      id: id,
      outputFormat: outputFormat,
      video: video,
      imageBytes: imageBytes,
      imageLayers: imageLayers,
      transform: transform,
      enableAudio: enableAudio,
      playbackSpeed: playbackSpeed,
      startTime: startTime,
      endTime: endTime,
      blur: blur,
      bitrate: bitrateOverride ?? qualityConfig.bitrate,
      colorMatrixList: colorMatrixList,
      qualityConfig: qualityConfig,
      customAudioPath: customAudioPath,
      customAudioStartTime: customAudioStartTime,
      originalAudioVolume: originalAudioVolume,
      customAudioVolume: customAudioVolume,
      shouldOptimizeForNetworkUse: shouldOptimizeForNetworkUse,
      imageBytesWithCropping: imageBytesWithCropping,
      loopCustomAudio: loopCustomAudio,
    );
  }

  /// Unique ID for the task, useful when running multiple tasks at once.
  final String id;

  /// Configuration class that defines video quality parameters.
  final VideoQualityConfig? qualityConfig;

  /// The target format for the exported video.
  final VideoOutputFormat outputFormat;

  /// A model that encapsulates various ways to load and represent a video.
  ///
  /// This class supports videos from in-memory bytes, file system, network,
  /// or asset bundle. It provides convenience methods for identifying the
  /// source type and safely retrieving video bytes.
  ///
  /// **Note:** Either [video] or [videoSegments] must be provided, but not
  /// both.
  /// Use this field for a single video. For concatenating multiple videos,
  /// use [videoSegments] instead.
  final EditorVideo? video;

  /// A list of video clips to be concatenated into a single output video.
  ///
  /// Each clip can have its own start and end time for trimming. The clips
  /// will be joined in the order they appear in the list.
  ///
  /// **Note:** Either [video] or [videoSegments] must be provided, but not
  /// both.
  /// Use this field for concatenating multiple videos. For a single video,
  /// use [video] instead.
  ///
  /// **Example:**
  /// ```dart
  /// videoSegments: [
  ///   VideoClipModel(
  ///     video: EditorVideo.file('video1.mp4'),
  ///     startTime: Duration(seconds: 0),
  ///     endTime: Duration(seconds: 5),
  ///   ),
  ///   VideoClipModel(
  ///     video: EditorVideo.file('video2.mp4'),
  ///     startTime: Duration(seconds: 2),
  ///     endTime: Duration(seconds: 8),
  ///   ),
  /// ]
  /// ```
  final List<VideoSegment>? videoSegments;

  /// A transparent image which will overlay the video.
  final Uint8List? imageBytes;

  /// A list of image layers with timing information for overlaying on the video
  final List<ImageLayer> imageLayers;

  /// Transformation settings like resize, rotation, offset, and flipping.
  ///
  /// Used to control how the video or image is positioned and modified during
  /// export.
  final ExportTransform? transform;

  /// Whether to include audio in the exported video.
  ///
  /// **Default**: `true`
  final bool enableAudio;

  /// Playback speed of the exported video.
  ///
  /// For example, `0.5` for half speed, `2.0` for double speed.
  final double? playbackSpeed;

  /// Optional start time for trimming the video.
  final Duration? startTime;

  /// Optional end time for trimming the video.
  final Duration? endTime;

  /// A 4x5 matrix used to apply color filters (e.g., saturation, brightness).
  final List<List<double>> colorMatrixList;

  /// Amount of blur to apply.
  ///
  /// Higher values result in a stronger blur effect.
  final double? blur;

  /// The bitrate of the video in bits per second.
  ///
  /// This value is optional and may be `null` if the bitrate is not specified.
  ///
  /// **WARNING Android:** Not all devices support CBR (Constant Bitrate) mode.
  /// If unsupported, the encoder may silently fall back to VBR
  /// (Variable Bitrate), and the actual bitrate may be constrained by
  /// device-specific minimum and maximum limits.
  ///
  /// **WARNING macOS iOS** It's not supported to directly set a specific
  /// bitrate, instant it will choose a preset which is the most near to the
  /// applied bitrate.
  final int? bitrate;

  /// Path to a custom audio file to be mixed with the video.
  ///
  /// When provided, this audio will be mixed with the original video audio.
  /// Use [originalAudioVolume] and [customAudioVolume] to control the mix
  /// levels of each audio track.
  final String? customAudioPath;

  /// The start time offset for the custom audio track.
  ///
  /// When provided, the custom audio will start playing from this position
  /// instead of from the beginning. This is useful for using a specific
  /// section of a longer audio file.
  ///
  /// This parameter is only effective when [customAudioPath] is provided.
  final Duration? customAudioStartTime;

  /// Volume multiplier for the original video audio track.
  ///
  /// - Range: `0.0` (mute) to `1.0+` (amplify)
  /// - Default: `1.0` (unchanged)
  ///
  /// **Examples:**
  /// - `0.0`: Mute original audio completely
  /// - `0.5`: Reduce original audio to 50%
  /// - `1.0`: Keep original volume (default)
  /// - `1.5`: Amplify original audio by 50%
  /// - `2.0`: Double the original volume
  ///
  /// This parameter is only effective when [enableAudio] is `true`.
  final double? originalAudioVolume;

  /// Volume multiplier for the custom audio track.
  ///
  /// - Range: `0.0` (mute) to `1.0+` (amplify)
  /// - Default: `1.0` (unchanged)
  ///
  /// **Examples:**
  /// - `0.0`: Mute custom audio
  /// - `0.3`: Subtle background music (30%)
  /// - `0.5`: Equal mix with original audio
  /// - `1.0`: Full volume (default)
  /// - `1.2`: Slightly amplified
  ///
  /// This parameter is only effective when [customAudioPath] is provided.
  final double? customAudioVolume;

  /// Whether to optimize the video for network streaming (fast start).
  ///
  /// When `true`, the video metadata (moov atom) is moved to the beginning
  /// of the file, enabling progressive playback/streaming in browsers and
  /// media players.
  ///
  /// This fixes the "mdat before moov" issue where the video index is at
  /// the END of the file instead of the beginning, preventing browsers from
  /// streaming progressively.
  ///
  /// **Default**: `false`
  ///
  /// **Recommended:** Keep this `true` for videos intended for web playback
  /// or streaming. Set it to `false` if file size or encoding speed is
  /// more critical than streaming capability.
  final bool shouldOptimizeForNetworkUse;

  /// Whether to apply cropping to the image overlay along with the video.
  ///
  /// When `false` (default), the [imageBytes] amd [imageLayers] overlays
  /// are scaled to match the **final** video dimensions (after cropping).
  /// The overlay covers the entire output frame.
  ///
  /// When `true`, the [imageBytes] and [imageLayers] overlays are scaled
  /// to match the **original** video dimensions (before cropping), and then
  /// the same crop is applied to both the video and the overlay together.
  /// This is useful when the overlay contains elements that should be
  /// cropped in sync with the video content.
  ///
  /// **Default**: `false`
  ///
  /// **Example:**
  /// - `false`: Overlay stretches to fill the cropped output
  /// - `true`: Overlay is cropped together with the video
  final bool imageBytesWithCropping;

  /// Whether to loop the custom audio track if it is shorter than the video.
  ///
  /// When `true` (default), the custom audio will be repeated until it
  /// matches the video duration. When `false`, the audio plays once and
  /// silence fills the remaining duration.
  ///
  /// This parameter is only effective when [customAudioPath] is provided.
  ///
  /// **Default**: `true`
  final bool loopCustomAudio;

  /// Returns a [Stream] of [ProgressModel] objects that provides updates on
  /// the progress of the video rendering process associated with this model's
  /// [id].
  ///
  /// The stream is obtained from the [ProVideoEditor] singleton instance and
  /// is specific to the current video's identifier.
  Stream<ProgressModel> get progressStream {
    return ProVideoEditor.instance.progressStreamById(id);
  }

  /// Converts the model into a serializable map.
  Future<Map<String, dynamic>> toAsyncMap() async {
    var transform = this.transform ?? const ExportTransform();

    double? scaleX = transform.scaleX;
    double? scaleY = transform.scaleY;

    // Handle quality config for single video
    if (qualityConfig != null &&
        scaleX == null &&
        scaleY == null &&
        video != null) {
      final meta = await ProVideoEditor.instance.getMetadata(video!);
      final originalResolution = meta.resolution;
      final targetResolution = qualityConfig!.resolution ?? originalResolution;
      scaleX = targetResolution.width / originalResolution.width;
      scaleY = targetResolution.height / originalResolution.height;
    }

    // Convert video clips to map format
    List<Map<String, dynamic>>? videoSegmentsMaps;
    if (videoSegments != null) {
      videoSegmentsMaps = await Future.wait(
        videoSegments!.map((clip) => clip.toAsyncMap()),
      );
    } else if (video != null) {
      // Single video: convert to single clip format
      videoSegmentsMaps = [
        {
          'inputPath': await video!.safeFilePath(),
          'startUs': startTime?.inMicroseconds,
          'endUs': endTime?.inMicroseconds,
        },
      ];
    }

    return {
      ...transform.toMap(),
      'id': id,
      'videoClips': videoSegmentsMaps,
      'imageBytes': imageBytes,
      'imageLayers': await Future.wait(
        imageLayers.map((layer) async => {
              'imageData': await layer.image.safeByteArray(),
              'startUs': layer.startTime.inMicroseconds,
              'endUs': layer.endTime?.inMicroseconds,
            }),
      ),
      'enableAudio': enableAudio,
      'playbackSpeed': playbackSpeed,
      'colorMatrixList': colorMatrixList,
      'outputFormat': outputFormat.name,
      'blur': blur,
      'bitrate': bitrate,
      'scaleX': scaleX,
      'scaleY': scaleY,
      'customAudioPath': customAudioPath,
      'customAudioStartTimeUs': customAudioStartTime?.inMicroseconds,
      'originalAudioVolume': originalAudioVolume,
      'customAudioVolume': customAudioVolume,
      // Global trim for entire composition (only for videoSegments,
      // not single video). For single video, startTime/endTime are already
      // applied to the clip itself
      'startUs': videoSegments != null ? startTime?.inMicroseconds : null,
      'endUs': videoSegments != null ? endTime?.inMicroseconds : null,
      'shouldOptimizeForNetworkUse': shouldOptimizeForNetworkUse,
      'imageBytesWithCropping': imageBytesWithCropping,
      'loopCustomAudio': loopCustomAudio,
    };
  }

  /// Creates a copy with updated values.
  VideoRenderData copyWith({
    String? id,
    VideoOutputFormat? outputFormat,
    EditorVideo? video,
    List<VideoSegment>? videoSegments,
    Uint8List? imageBytes,
    List<ImageLayer>? imageLayers,
    ExportTransform? transform,
    bool? enableAudio,
    double? playbackSpeed,
    Duration? startTime,
    Duration? endTime,
    List<List<double>>? colorMatrixList,
    double? blur,
    int? bitrate,
    VideoQualityConfig? qualityConfig,
    String? customAudioPath,
    Duration? customAudioStartTime,
    double? originalAudioVolume,
    double? customAudioVolume,
    bool? shouldOptimizeForNetworkUse,
    bool? imageBytesWithCropping,
    bool? loopCustomAudio,
  }) {
    return VideoRenderData(
      id: id ?? this.id,
      outputFormat: outputFormat ?? this.outputFormat,
      video: video ?? this.video,
      videoSegments: videoSegments ?? this.videoSegments,
      imageBytes: imageBytes ?? this.imageBytes,
      imageLayers: imageLayers ?? this.imageLayers,
      transform: transform ?? this.transform,
      enableAudio: enableAudio ?? this.enableAudio,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      colorMatrixList: colorMatrixList ?? this.colorMatrixList,
      blur: blur ?? this.blur,
      bitrate: bitrate ?? this.bitrate,
      qualityConfig: qualityConfig ?? this.qualityConfig,
      customAudioPath: customAudioPath ?? this.customAudioPath,
      customAudioStartTime: customAudioStartTime ?? this.customAudioStartTime,
      originalAudioVolume: originalAudioVolume ?? this.originalAudioVolume,
      customAudioVolume: customAudioVolume ?? this.customAudioVolume,
      shouldOptimizeForNetworkUse:
          shouldOptimizeForNetworkUse ?? this.shouldOptimizeForNetworkUse,
      imageBytesWithCropping:
          imageBytesWithCropping ?? this.imageBytesWithCropping,
      loopCustomAudio: loopCustomAudio ?? this.loopCustomAudio,
    );
  }
}

/// Supported video output formats for export.
enum VideoOutputFormat {
  /// MPEG-4 Part 14, widely supported.
  mp4,

  /// mov format.
  ///
  /// Only supported on macos and ios.
  mov,
}
