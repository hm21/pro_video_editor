// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

/// A model describing settings for rendering or exporting a video.
///
/// Includes input video data (a single track of clips or a layered
/// composition), optional overlays, transformations, color filters, audio
/// options, and output format.
class VideoRenderData {
  /// Creates a [VideoRenderData] with the given parameters.
  ///
  /// **Important:** You must provide exactly one of [videoSegments] or
  /// [composition].
  /// - Use [videoSegments] for concatenating one or more videos into one track,
  ///   each with their own trim settings
  /// - Use [composition] for multiple layered tracks that overlap in time or
  ///   space (picture-in-picture, side-by-side, grid)
  VideoRenderData({
    String? id,
    this.qualityConfig,
    this.outputFormat = VideoOutputFormat.mp4,
    this.videoSegments,
    this.composition,
    this.imageLayers,
    this.transform,
    this.enableAudio = true,
    this.startTime,
    this.endTime,
    this.colorFilters = const [],
    this.audioTracks = const [],
    this.blur,
    this.bitrate,
    this.shouldOptimizeForNetworkUse = false,
    this.imageBytesWithCropping = false,
  })  : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        assert(
          (videoSegments != null ? 1 : 0) + (composition != null ? 1 : 0) == 1,
          'You must provide exactly one of videoSegments or composition',
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
          bitrate == null || bitrate > 0,
          '[bitrate] must be greater than 0',
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
  ///   videoSegments: [VideoSegment(video: EditorVideo.asset('assets/v.mp4'))],
  ///   qualityPreset: VideoQualityPreset.p1080,
  ///   outputFormat: VideoOutputFormat.mp4,
  /// );
  /// ```
  ///
  /// You can override the preset's resolution by providing a custom
  /// [transform] with scale or crop settings. The bitrate from the preset
  /// will still be used unless explicitly overridden with [bitrateOverride].
  factory VideoRenderData.withQualityPreset({
    List<VideoSegment>? videoSegments,
    VideoComposition? composition,
    required VideoQualityPreset qualityPreset,
    VideoOutputFormat outputFormat = VideoOutputFormat.mp4,
    List<ImageLayer> imageLayers = const [],
    ExportTransform? transform,
    bool enableAudio = true,
    Duration? startTime,
    Duration? endTime,
    double? blur,
    int? bitrateOverride,
    List<ColorFilter> colorFilters = const [],
    List<VideoAudioTrack> audioTracks = const [],
    bool shouldOptimizeForNetworkUse = false,
    bool imageBytesWithCropping = false,
    String? id,
  }) {
    final qualityConfig = VideoQualityConfig.fromPreset(qualityPreset);

    return VideoRenderData(
      id: id,
      outputFormat: outputFormat,
      videoSegments: videoSegments,
      composition: composition,
      imageLayers: imageLayers,
      transform: transform,
      enableAudio: enableAudio,
      startTime: startTime,
      endTime: endTime,
      blur: blur,
      bitrate: bitrateOverride ?? qualityConfig.bitrate,
      colorFilters: colorFilters,
      audioTracks: audioTracks,
      qualityConfig: qualityConfig,
      shouldOptimizeForNetworkUse: shouldOptimizeForNetworkUse,
      imageBytesWithCropping: imageBytesWithCropping,
    );
  }

  /// Unique ID for the task, useful when running multiple tasks at once.
  final String id;

  /// Configuration class that defines video quality parameters.
  final VideoQualityConfig? qualityConfig;

  /// The target format for the exported video.
  final VideoOutputFormat outputFormat;

  /// A list of video clips to be concatenated into a single output video.
  ///
  /// Each clip can have its own start and end time for trimming. The clips
  /// will be joined in the order they appear in the list.
  ///
  /// **Note:** Exactly one of [videoSegments] or [composition] must be
  /// provided. Use this field for a single track of concatenated clips, and
  /// [composition] when layers overlap in time or space.
  ///
  /// **Example:**
  /// ```dart
  /// videoSegments: [
  ///   VideoSegment(
  ///     video: EditorVideo.file('video1.mp4'),
  ///     startTime: Duration(seconds: 0),
  ///     endTime: Duration(seconds: 5),
  ///   ),
  ///   VideoSegment(video: EditorVideo.file('video2.mp4')),
  /// ]
  /// ```
  final List<VideoSegment>? videoSegments;

  /// A multi-layer composition for spatially arranging several videos.
  ///
  /// Use this to place videos next to each other, in a grid, or as
  /// picture-in-picture overlays. Each [VideoLayer] is a track with its own
  /// time-ordered clips; layers are composited bottom-to-top.
  ///
  /// **Note:** Exactly one of [videoSegments] or [composition] must be
  /// provided. Use [videoSegments] for a single track of concatenated clips,
  /// and [composition] when layers overlap in time or space.
  final VideoComposition? composition;

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

  /// Optional start time for trimming the entire composition across all
  /// segments.
  final Duration? startTime;

  /// Optional end time for trimming the entire composition across all
  /// segments.
  final Duration? endTime;

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
  /// When `false` (default), the [imageLayers] overlays are scaled to match
  /// the **final** video dimensions (after cropping). The overlay covers the
  /// entire output frame.
  ///
  /// When `true`, the [imageLayers] overlays are scaled to match the
  /// **original** video dimensions (before cropping), and then the same crop
  /// is applied to both the video and the overlay together. This is useful
  /// when the overlay contains elements that should be cropped in sync with
  /// the video content.
  ///
  /// **Default**: `false`
  ///
  /// **Example:**
  /// - `false`: Overlay stretches to fill the cropped output
  /// - `true`: Overlay is cropped together with the video
  final bool imageBytesWithCropping;

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
      final targetVideo = (videoSegments != null && videoSegments!.isNotEmpty
              ? videoSegments!.first.video
              : null) ??
          composition?.layers.first.clips.first.video;
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

    // Convert video clips to map format.
    List<Map<String, dynamic>>? videoSegmentsMaps;
    if (videoSegments != null) {
      videoSegmentsMaps = await Future.wait(
        videoSegments!.map((clip) => clip.toAsyncMap()),
      );
    }

    final colorFilterMaps = colorFilters
        .map(
          (f) => {
            'matrix': f.matrix,
            'startUs': f.startTime?.inMicroseconds,
            'endUs': f.endTime?.inMicroseconds,
          },
        )
        .toList();

    final audioTrackMaps = audioTracks
        .map(
          (t) => {
            'path': t.path,
            'volume': t.volume,
            'loop': t.loop,
            'audioStartUs': t.audioStartTime?.inMicroseconds,
            'audioEndUs': t.audioEndTime?.inMicroseconds,
            'startUs': t.startTime?.inMicroseconds,
            'endUs': t.endTime?.inMicroseconds,
          },
        )
        .toList();

    final imageLayerMaps = imageLayers == null
        ? <Map<String, dynamic>>[]
        : await Future.wait(
            imageLayers!.map(
              (layer) async => {
                'imageData': await layer.image.safeByteArray(),
                'startUs': layer.startTime?.inMicroseconds,
                'endUs': layer.endTime?.inMicroseconds,
                'x': layer.offset?.dx.toInt(),
                'y': layer.offset?.dy.toInt(),
                'width': layer.size?.width,
                'height': layer.size?.height,
                'animations': layer.animations.map((a) => a.toMap()).toList(),
              },
            ),
          );

    return {
      ...transform.toMap(),
      'id': id,
      'videoClips': videoSegmentsMaps,
      'composition':
          composition != null ? await composition!.toAsyncMap() : null,
      'imageLayers': imageLayerMaps,
      'colorFilters': colorFilterMaps,
      'audioTracks': audioTrackMaps,
      'enableAudio': enableAudio,
      'outputFormat': outputFormat.name,
      'blur': blur,
      'bitrate': bitrate,
      'scaleX': scaleX,
      'scaleY': scaleY,
      // Global trim across the whole timeline (for videoSegments and
      // compositions).
      'startUs': startTime?.inMicroseconds,
      'endUs': endTime?.inMicroseconds,
      'shouldOptimizeForNetworkUse': shouldOptimizeForNetworkUse,
      'imageBytesWithCropping': imageBytesWithCropping,
    };
  }

  /// Creates a copy with updated values.
  VideoRenderData copyWith({
    String? id,
    VideoQualityConfig? qualityConfig,
    VideoOutputFormat? outputFormat,
    List<VideoSegment>? videoSegments,
    VideoComposition? composition,
    List<ImageLayer>? imageLayers,
    ExportTransform? transform,
    bool? enableAudio,
    Duration? startTime,
    Duration? endTime,
    List<ColorFilter>? colorFilters,
    List<VideoAudioTrack>? audioTracks,
    double? blur,
    int? bitrate,
    bool? shouldOptimizeForNetworkUse,
    bool? imageBytesWithCropping,
  }) {
    return VideoRenderData(
      id: id ?? this.id,
      qualityConfig: qualityConfig ?? this.qualityConfig,
      outputFormat: outputFormat ?? this.outputFormat,
      videoSegments: videoSegments ?? this.videoSegments,
      composition: composition ?? this.composition,
      imageLayers: imageLayers ?? this.imageLayers,
      transform: transform ?? this.transform,
      enableAudio: enableAudio ?? this.enableAudio,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      colorFilters: colorFilters ?? this.colorFilters,
      audioTracks: audioTracks ?? this.audioTracks,
      blur: blur ?? this.blur,
      bitrate: bitrate ?? this.bitrate,
      shouldOptimizeForNetworkUse:
          shouldOptimizeForNetworkUse ?? this.shouldOptimizeForNetworkUse,
      imageBytesWithCropping:
          imageBytesWithCropping ?? this.imageBytesWithCropping,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'qualityConfig': qualityConfig?.toMap(),
      'outputFormat': outputFormat.name,
      'videoSegments': videoSegments?.map((x) => x.toMap()).toList(),
      'composition': composition?.toMap(),
      'imageLayers': imageLayers?.map((x) => x.toMap()).toList(),
      'transform': transform?.toMap(),
      'enableAudio': enableAudio,
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
      'colorFilters': colorFilters.map((x) => x.toMap()).toList(),
      'audioTracks': audioTracks.map((x) => x.toMap()).toList(),
      'blur': blur,
      'bitrate': bitrate,
      'shouldOptimizeForNetworkUse': shouldOptimizeForNetworkUse,
      'imageBytesWithCropping': imageBytesWithCropping,
    };
  }

  factory VideoRenderData.fromMap(Map<String, dynamic> map) {
    return VideoRenderData(
      id: map['id'] as String,
      qualityConfig: map['qualityConfig'] != null
          ? VideoQualityConfig.fromMap(
              map['qualityConfig'] as Map<String, dynamic>,
            )
          : null,
      outputFormat: VideoOutputFormat.values.byName(
        map['outputFormat'] as String,
      ),
      videoSegments: map['videoSegments'] != null
          ? List<VideoSegment>.from(
              (map['videoSegments'] as List).map<VideoSegment>(
                (x) => VideoSegment.fromMap(x as Map<String, dynamic>),
              ),
            )
          : null,
      composition: map['composition'] != null
          ? VideoComposition.fromMap(map['composition'] as Map<String, dynamic>)
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
      startTime: map['startTime'] != null
          ? Duration(microseconds: safeParseInt(map['startTime']))
          : null,
      endTime: map['endTime'] != null
          ? Duration(microseconds: safeParseInt(map['endTime']))
          : null,
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
      shouldOptimizeForNetworkUse: map['shouldOptimizeForNetworkUse'] as bool,
      imageBytesWithCropping: map['imageBytesWithCropping'] as bool,
    );
  }

  String toJson() => json.encode(toMap());

  factory VideoRenderData.fromJson(String source) =>
      VideoRenderData.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() {
    return 'VideoRenderData(id: $id, '
        'qualityConfig: $qualityConfig, '
        'outputFormat: $outputFormat, '
        'videoSegments: $videoSegments, '
        'composition: $composition, '
        'imageLayers: $imageLayers, '
        'transform: $transform, '
        'enableAudio: $enableAudio, '
        'startTime: $startTime, '
        'endTime: $endTime, '
        'colorFilters: $colorFilters, '
        'audioTracks: $audioTracks, '
        'blur: $blur, '
        'bitrate: $bitrate, '
        'shouldOptimizeForNetworkUse: $shouldOptimizeForNetworkUse, '
        'imageBytesWithCropping: $imageBytesWithCropping)';
  }

  @override
  bool operator ==(covariant VideoRenderData other) {
    if (identical(this, other)) return true;

    return other.id == id &&
        other.qualityConfig == qualityConfig &&
        other.outputFormat == outputFormat &&
        listEquals(other.videoSegments, videoSegments) &&
        other.composition == composition &&
        listEquals(other.imageLayers, imageLayers) &&
        other.transform == transform &&
        other.enableAudio == enableAudio &&
        other.startTime == startTime &&
        other.endTime == endTime &&
        listEquals(other.colorFilters, colorFilters) &&
        listEquals(other.audioTracks, audioTracks) &&
        other.blur == blur &&
        other.bitrate == bitrate &&
        other.shouldOptimizeForNetworkUse == shouldOptimizeForNetworkUse &&
        other.imageBytesWithCropping == imageBytesWithCropping;
  }

  @override
  int get hashCode {
    return id.hashCode ^
        qualityConfig.hashCode ^
        outputFormat.hashCode ^
        videoSegments.hashCode ^
        composition.hashCode ^
        imageLayers.hashCode ^
        transform.hashCode ^
        enableAudio.hashCode ^
        startTime.hashCode ^
        endTime.hashCode ^
        colorFilters.hashCode ^
        audioTracks.hashCode ^
        blur.hashCode ^
        bitrate.hashCode ^
        shouldOptimizeForNetworkUse.hashCode ^
        imageBytesWithCropping.hashCode;
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
