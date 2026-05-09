// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

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
    String? id,
    this.qualityConfig,
    this.outputFormat = VideoOutputFormat.mp4,
    @Deprecated('Use videoSegments instead.') this.video,
    this.videoSegments,
    @Deprecated('Use imageLayers instead.') this.imageBytes,
    this.imageLayers,
    this.transform,
    this.enableAudio = true,
    @Deprecated('Use VideoSegment.playbackSpeed instead.') this.playbackSpeed,
    this.startTime,
    this.endTime,
    @Deprecated('Use colorFilters instead.') this.colorMatrixList = const [],
    this.colorFilters = const [],
    this.audioTracks = const [],
    this.blur,
    this.bitrate,
    @Deprecated('Use audioTracks instead.') this.customAudioPath,
    @Deprecated('Use audioTracks instead.') this.customAudioStartTime,
    @Deprecated('Use VideoSegment.volume instead.') this.originalAudioVolume,
    @Deprecated('Use audioTracks instead.') this.customAudioVolume,
    this.shouldOptimizeForNetworkUse = false,
    this.imageBytesWithCropping = false,
    @Deprecated('Use audioTracks instead.') this.loopCustomAudio = true,
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
          imageBytes == null || imageLayers == null || imageLayers.isEmpty,
          'Cannot use both imageBytes and imageLayers. '
          'Use imageLayers instead.',
        ),
        assert(
          colorMatrixList.isEmpty || colorFilters.isEmpty,
          'Cannot use both colorMatrixList and colorFilters. '
          'Use colorFilters instead.',
        ),
        assert(
          audioTracks.isEmpty ||
              (customAudioPath == null &&
                  customAudioStartTime == null &&
                  customAudioVolume == null),
          'Cannot use both audioTracks and customAudio* fields. '
          'Use audioTracks instead.',
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
    @Deprecated('Use videoSegments instead.') EditorVideo? video,
    List<VideoSegment>? videoSegments,
    required VideoQualityPreset qualityPreset,
    VideoOutputFormat outputFormat = VideoOutputFormat.mp4,
    @Deprecated('Use imageLayers instead.') Uint8List? imageBytes,
    List<ImageLayer> imageLayers = const [],
    ExportTransform? transform,
    bool enableAudio = true,
    @Deprecated('Use VideoSegment.playbackSpeed instead.')
    double? playbackSpeed,
    Duration? startTime,
    Duration? endTime,
    double? blur,
    int? bitrateOverride,
    @Deprecated('Use colorFilters instead.')
    List<List<double>> colorMatrixList = const [],
    List<ColorFilter> colorFilters = const [],
    List<VideoAudioTrack> audioTracks = const [],
    @Deprecated('Use audioTracks instead.') String? customAudioPath,
    @Deprecated('Use audioTracks instead.') Duration? customAudioStartTime,
    @Deprecated('Use VideoSegment.volume instead.') double? originalAudioVolume,
    @Deprecated('Use audioTracks instead.') double? customAudioVolume,
    bool shouldOptimizeForNetworkUse = false,
    bool imageBytesWithCropping = false,
    @Deprecated('Use audioTracks instead.') bool loopCustomAudio = true,
    String? id,
  }) {
    final qualityConfig = VideoQualityConfig.fromPreset(qualityPreset);

    return VideoRenderData(
      id: id,
      outputFormat: outputFormat,
      video: video,
      videoSegments: videoSegments,
      imageBytes: imageBytes,
      imageLayers: imageLayers,
      transform: transform,
      enableAudio: enableAudio,
      // ignore: deprecated_member_use_from_same_package
      playbackSpeed: playbackSpeed,
      startTime: startTime,
      endTime: endTime,
      blur: blur,
      bitrate: bitrateOverride ?? qualityConfig.bitrate,
      // ignore: deprecated_member_use_from_same_package
      colorMatrixList: colorMatrixList,
      colorFilters: colorFilters,
      audioTracks: audioTracks,
      qualityConfig: qualityConfig,
      // ignore: deprecated_member_use_from_same_package
      customAudioPath: customAudioPath,
      // ignore: deprecated_member_use_from_same_package
      customAudioStartTime: customAudioStartTime,
      // ignore: deprecated_member_use_from_same_package
      originalAudioVolume: originalAudioVolume,
      // ignore: deprecated_member_use_from_same_package
      customAudioVolume: customAudioVolume,
      shouldOptimizeForNetworkUse: shouldOptimizeForNetworkUse,
      imageBytesWithCropping: imageBytesWithCropping,
      // ignore: deprecated_member_use_from_same_package
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
  @Deprecated('Use videoSegments instead.')
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
  @Deprecated('Use imageLayers instead.')
  final Uint8List? imageBytes;

  /// A list of image layers with timing information for overlaying on the video
  final List<ImageLayer>? imageLayers;

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
  @Deprecated('Use VideoSegment.playbackSpeed instead.')
  final double? playbackSpeed;

  /// Optional start time for trimming the entire composition across all
  /// segments.
  final Duration? startTime;

  /// Optional end time for trimming the entire composition across all
  /// segments.
  final Duration? endTime;

  /// A 4x5 matrix used to apply color filters (e.g., saturation, brightness).
  @Deprecated('Use colorFilters instead.')
  final List<List<double>> colorMatrixList;

  /// A list of color filters with optional time ranges.
  ///
  /// Each filter applies a color matrix to the video, optionally
  /// restricted to a specific time range.
  final List<ColorFilter> colorFilters;

  /// A list of audio tracks with optional time ranges.
  ///
  /// Each track adds audio to the video, optionally restricted
  /// to a specific time range.
  final List<VideoAudioTrack> audioTracks;

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
  @Deprecated('Use audioTracks instead.')
  final String? customAudioPath;

  /// The start time offset for the custom audio track.
  ///
  /// When provided, the custom audio will start playing from this position
  /// instead of from the beginning. This is useful for using a specific
  /// section of a longer audio file.
  ///
  /// This parameter is only effective when [customAudioPath] is provided.
  @Deprecated('Use audioTracks instead.')
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
  @Deprecated('Use VideoSegment.volume instead.')
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
  @Deprecated('Use audioTracks instead.')
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
  @Deprecated('Use audioTracks instead.')
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

    // Handle quality config
    if (qualityConfig != null && scaleX == null && scaleY == null) {
      final targetVideo = video ??
          (videoSegments != null && videoSegments!.isNotEmpty
              ? videoSegments!.first.video
              : null);
      if (targetVideo != null) {
        final meta = await ProVideoEditor.instance.getMetadata(targetVideo);
        final originalResolution = meta.resolution;
        final targetResolution =
            qualityConfig!.resolution ?? originalResolution;
        final sx = targetResolution.width / originalResolution.width;
        final sy = targetResolution.height / originalResolution.height;
        final scale = sx < sy ? sx : sy;
        scaleX = scale;
        scaleY = scale;
      }
    }

    // Convert video clips to map format
    // ignore: deprecated_member_use_from_same_package
    final fallbackVolume = originalAudioVolume;
    List<Map<String, dynamic>>? videoSegmentsMaps;
    if (videoSegments != null) {
      videoSegmentsMaps = await Future.wait(
        videoSegments!.map((clip) async => {
              ...await clip.toAsyncMap(),
              'volume': clip.volume ?? fallbackVolume,
            }),
      );
    } else if (video != null) {
      // Single video: convert to single clip format
      videoSegmentsMaps = [
        {
          // ignore: deprecated_member_use_from_same_package
          'inputPath': await video!.safeFilePath(),
          'startUs': startTime?.inMicroseconds,
          'endUs': endTime?.inMicroseconds,
          'volume': fallbackVolume,
        },
      ];
    }

    // Merge deprecated colorMatrixList into colorFilters
    // ignore: deprecated_member_use_from_same_package
    final mergedColorFilters = [
      ...colorFilters.map((f) => {
            'matrix': f.matrix,
            'startUs': f.startTime?.inMicroseconds,
            'endUs': f.endTime?.inMicroseconds,
          }),
      // ignore: deprecated_member_use_from_same_package
      ...colorMatrixList.map((matrix) => {
            'matrix': matrix,
            'startUs': null,
            'endUs': null,
          }),
    ];

    // Merge deprecated customAudio* fields into audioTracks
    final mergedAudioTracks = [
      ...audioTracks.map((t) => {
            'path': t.path,
            'volume': t.volume,
            'loop': t.loop,
            'audioStartUs': t.audioStartTime?.inMicroseconds,
            'audioEndUs': t.audioEndTime?.inMicroseconds,
            'startUs': t.startTime?.inMicroseconds,
            'endUs': t.endTime?.inMicroseconds,
          }),
      // ignore: deprecated_member_use_from_same_package
      if (customAudioPath != null)
        {
          // ignore: deprecated_member_use_from_same_package
          'path': customAudioPath,
          // ignore: deprecated_member_use_from_same_package
          'volume': customAudioVolume ?? 1.0,
          // ignore: deprecated_member_use_from_same_package
          'loop': loopCustomAudio,
          // ignore: deprecated_member_use_from_same_package
          'audioStartUs': customAudioStartTime?.inMicroseconds,
          'audioEndUs': null,
          'startUs': null,
          'endUs': null,
        },
    ];

    // Merge deprecated imageBytes into imageLayers
    final mergedImageLayers = [
      if (imageLayers != null)
        ...await Future.wait(
          imageLayers!.map((layer) async => {
                'imageData': await layer.image.safeByteArray(),
                'startUs': layer.startTime?.inMicroseconds,
                'endUs': layer.endTime?.inMicroseconds,
                'x': layer.offset?.dx.toInt(),
                'y': layer.offset?.dy.toInt(),
                'width': layer.size?.width,
                'height': layer.size?.height,
                'animations': layer.animations.map((a) => a.toMap()).toList(),
              }),
        ),
      // ignore: deprecated_member_use_from_same_package
      if (imageBytes != null)
        {
          // ignore: deprecated_member_use_from_same_package
          'imageData': imageBytes,
          'startUs': null,
          'endUs': null,
          'x': null,
          'y': null,
        },
    ];

    return {
      ...transform.toMap(),
      'id': id,
      'videoClips': videoSegmentsMaps,
      'imageLayers': mergedImageLayers,
      'colorFilters': mergedColorFilters,
      'audioTracks': mergedAudioTracks,
      'enableAudio': enableAudio,
      'playbackSpeed': playbackSpeed,
      'outputFormat': outputFormat.name,
      'blur': blur,
      'bitrate': bitrate,
      'scaleX': scaleX,
      'scaleY': scaleY,
      // Global trim for entire composition (only for videoSegments,
      // not single video). For single video, startTime/endTime are already
      // applied to the clip itself
      'startUs': videoSegments != null ? startTime?.inMicroseconds : null,
      'endUs': videoSegments != null ? endTime?.inMicroseconds : null,
      'shouldOptimizeForNetworkUse': shouldOptimizeForNetworkUse,
      'imageBytesWithCropping': imageBytesWithCropping,
    };
  }

  /// Creates a copy with updated values.
  VideoRenderData copyWith({
    String? id,
    VideoQualityConfig? qualityConfig,
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
    List<ColorFilter>? colorFilters,
    List<VideoAudioTrack>? audioTracks,
    double? blur,
    int? bitrate,
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
      qualityConfig: qualityConfig ?? this.qualityConfig,
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
      colorFilters: colorFilters ?? this.colorFilters,
      audioTracks: audioTracks ?? this.audioTracks,
      blur: blur ?? this.blur,
      bitrate: bitrate ?? this.bitrate,
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

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'qualityConfig': qualityConfig?.toMap(),
      'outputFormat': outputFormat.name,
      'video': video?.toMap(),
      'videoSegments': videoSegments?.map((x) => x.toMap()).toList(),
      'imageBytes': imageBytes?.toList(),
      'imageLayers': imageLayers?.map((x) => x.toMap()).toList(),
      'transform': transform?.toMap(),
      'enableAudio': enableAudio,
      'playbackSpeed': playbackSpeed,
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
      'colorMatrixList': colorMatrixList,
      'colorFilters': colorFilters.map((x) => x.toMap()).toList(),
      'audioTracks': audioTracks.map((x) => x.toMap()).toList(),
      'blur': blur,
      'bitrate': bitrate,
      'customAudioPath': customAudioPath,
      'customAudioStartTime': customAudioStartTime?.inMicroseconds,
      'originalAudioVolume': originalAudioVolume,
      'customAudioVolume': customAudioVolume,
      'shouldOptimizeForNetworkUse': shouldOptimizeForNetworkUse,
      'imageBytesWithCropping': imageBytesWithCropping,
      'loopCustomAudio': loopCustomAudio,
    };
  }

  factory VideoRenderData.fromMap(Map<String, dynamic> map) {
    return VideoRenderData(
      id: map['id'] as String,
      qualityConfig: map['qualityConfig'] != null
          ? VideoQualityConfig.fromMap(
              map['qualityConfig'] as Map<String, dynamic>)
          : null,
      outputFormat:
          VideoOutputFormat.values.byName(map['outputFormat'] as String),
      video: map['video'] != null
          ? EditorVideo.fromMap(map['video'] as Map<String, dynamic>)
          : null,
      videoSegments: map['videoSegments'] != null
          ? List<VideoSegment>.from(
              (map['videoSegments'] as List).map<VideoSegment>(
                (x) => VideoSegment.fromMap(x as Map<String, dynamic>),
              ),
            )
          : null,
      imageBytes: map['imageBytes'] != null
          ? Uint8List.fromList(List<int>.from(map['imageBytes'] as List))
          : null,
      imageLayers: map['imageLayers'] != null
          ? List<ImageLayer>.from(
              (map['imageLayers'] as List).map<ImageLayer>(
                (x) => ImageLayer.fromMap(x as Map<String, dynamic>),
              ),
            )
          : null,
      transform: map['transform'] != null
          ? ExportTransform.fromMap(map['transform'] as Map<String, dynamic>)
          : null,
      enableAudio: map['enableAudio'] as bool,
      playbackSpeed: tryParseDouble(map['playbackSpeed']),
      startTime: map['startTime'] != null
          ? Duration(microseconds: safeParseInt(map['startTime']))
          : null,
      endTime: map['endTime'] != null
          ? Duration(microseconds: safeParseInt(map['endTime']))
          : null,
      colorMatrixList: List<List<double>>.from(
        (map['colorMatrixList'] as List).map<List<double>>(
          (x) => List<double>.from(x as List),
        ),
      ),
      colorFilters: List<ColorFilter>.from(
        (map['colorFilters'] as List).map<ColorFilter>(
          (x) => ColorFilter.fromMap(x as Map<String, dynamic>),
        ),
      ),
      audioTracks: List<VideoAudioTrack>.from(
        (map['audioTracks'] as List).map<VideoAudioTrack>(
          (x) => VideoAudioTrack.fromMap(x as Map<String, dynamic>),
        ),
      ),
      blur: tryParseDouble(map['blur']),
      bitrate: map['bitrate'] != null ? safeParseInt(map['bitrate']) : null,
      customAudioPath: map['customAudioPath'] != null
          ? map['customAudioPath'] as String
          : null,
      customAudioStartTime: map['customAudioStartTime'] != null
          ? Duration(microseconds: safeParseInt(map['customAudioStartTime']))
          : null,
      originalAudioVolume: tryParseDouble(map['originalAudioVolume']),
      customAudioVolume: tryParseDouble(map['customAudioVolume']),
      shouldOptimizeForNetworkUse: map['shouldOptimizeForNetworkUse'] as bool,
      imageBytesWithCropping: map['imageBytesWithCropping'] as bool,
      loopCustomAudio: map['loopCustomAudio'] as bool,
    );
  }

  String toJson() => json.encode(toMap());

  factory VideoRenderData.fromJson(String source) =>
      VideoRenderData.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() {
    return 'VideoRenderData(id: $id, '
        'qualityConfig: $qualityConfig, '
        'outputFormat: $outputFormat, video: $video, '
        'videoSegments: $videoSegments, '
        'imageBytes: $imageBytes, '
        'imageLayers: $imageLayers, '
        'transform: $transform, '
        'enableAudio: $enableAudio, '
        'playbackSpeed: $playbackSpeed, '
        'startTime: $startTime, '
        'endTime: $endTime, '
        'colorMatrixList: $colorMatrixList, '
        'colorFilters: $colorFilters, '
        'audioTracks: $audioTracks, '
        'blur: $blur, '
        'bitrate: $bitrate, '
        'customAudioPath: $customAudioPath, '
        'customAudioStartTime: $customAudioStartTime, '
        'originalAudioVolume: $originalAudioVolume, '
        'customAudioVolume: $customAudioVolume, '
        'shouldOptimizeForNetworkUse: $shouldOptimizeForNetworkUse, '
        'imageBytesWithCropping: $imageBytesWithCropping, '
        'loopCustomAudio: $loopCustomAudio)';
  }

  @override
  bool operator ==(covariant VideoRenderData other) {
    if (identical(this, other)) return true;

    return other.id == id &&
        other.qualityConfig == qualityConfig &&
        other.outputFormat == outputFormat &&
        other.video == video &&
        listEquals(other.videoSegments, videoSegments) &&
        other.imageBytes == imageBytes &&
        listEquals(other.imageLayers, imageLayers) &&
        other.transform == transform &&
        other.enableAudio == enableAudio &&
        other.playbackSpeed == playbackSpeed &&
        other.startTime == startTime &&
        other.endTime == endTime &&
        listEquals(other.colorMatrixList, colorMatrixList) &&
        listEquals(other.colorFilters, colorFilters) &&
        listEquals(other.audioTracks, audioTracks) &&
        other.blur == blur &&
        other.bitrate == bitrate &&
        other.customAudioPath == customAudioPath &&
        other.customAudioStartTime == customAudioStartTime &&
        other.originalAudioVolume == originalAudioVolume &&
        other.customAudioVolume == customAudioVolume &&
        other.shouldOptimizeForNetworkUse == shouldOptimizeForNetworkUse &&
        other.imageBytesWithCropping == imageBytesWithCropping &&
        other.loopCustomAudio == loopCustomAudio;
  }

  @override
  int get hashCode {
    return id.hashCode ^
        qualityConfig.hashCode ^
        outputFormat.hashCode ^
        video.hashCode ^
        videoSegments.hashCode ^
        imageBytes.hashCode ^
        imageLayers.hashCode ^
        transform.hashCode ^
        enableAudio.hashCode ^
        playbackSpeed.hashCode ^
        startTime.hashCode ^
        endTime.hashCode ^
        colorMatrixList.hashCode ^
        colorFilters.hashCode ^
        audioTracks.hashCode ^
        blur.hashCode ^
        bitrate.hashCode ^
        customAudioPath.hashCode ^
        customAudioStartTime.hashCode ^
        originalAudioVolume.hashCode ^
        customAudioVolume.hashCode ^
        shouldOptimizeForNetworkUse.hashCode ^
        imageBytesWithCropping.hashCode ^
        loopCustomAudio.hashCode;
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
