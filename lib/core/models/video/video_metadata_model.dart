import 'dart:ui';

import '/shared/utils/parser/double_parser.dart';
import '/shared/utils/parser/int_parser.dart';

/// Represents GPS coordinates with latitude and longitude.
///
/// This class is used to store location information extracted from video
/// metadata, typically representing where the video was recorded.
class GpsCoordinates {
  /// Creates a [GpsCoordinates] instance.
  const GpsCoordinates({required this.latitude, required this.longitude});

  /// The GPS latitude coordinate.
  ///
  /// Positive values represent North, negative values represent South.
  ///
  /// Example:
  /// ```dart
  /// 47.3769 // Zurich, Switzerland (North)
  /// -33.8688 // Sydney, Australia (South)
  /// ```
  final double latitude;

  /// The GPS longitude coordinate.
  ///
  /// Positive values represent East, negative values represent West.
  ///
  /// Example:
  /// ```dart
  /// 8.5417 // Zurich, Switzerland (East)
  /// -122.4194 // San Francisco, USA (West)
  /// ```
  final double longitude;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GpsCoordinates &&
        other.latitude == latitude &&
        other.longitude == longitude;
  }

  @override
  int get hashCode => latitude.hashCode ^ longitude.hashCode;

  @override
  String toString() => 'GpsCoordinates($latitude, $longitude)';
}

/// A class that holds metadata information about a video.
class VideoMetadata {
  /// Creates a [VideoMetadata] instance.
  VideoMetadata({
    required this.duration,
    required this.extension,
    required this.fileSize,
    required this.resolution,
    required this.rotation,
    required this.bitrate,
    this.audioDuration,
    this.title = '',
    this.artist = '',
    this.author = '',
    this.album = '',
    this.albumArtist = '',
    this.date,
    this.isOptimizedForStreaming,
    this.gpsCoordinates,
    this.frameRate,
    this.cameraMake = '',
    this.cameraModel = '',
  });

  /// Creates a [VideoMetadata] instance from a map of data.
  ///
  /// The [value] map contains metadata values such as duration, resolution,
  /// file size, and others.
  /// The [extension] is the video file format (e.g., 'mp4').
  factory VideoMetadata.fromMap(Map<dynamic, dynamic> value, String extension) {
    // All platforms now return display dimensions (after rotation correction)
    final resolution = Size(
      safeParseDouble(value['width']),
      safeParseDouble(value['height']),
    );
    int rotation = safeParseInt(value['rotation']);

    return VideoMetadata(
      duration: Duration(milliseconds: safeParseInt(value['duration'])),
      extension: extension,
      fileSize: value['fileSize'] ?? 0,
      resolution: resolution,
      rotation: rotation,
      bitrate: safeParseInt(value['bitrate']),
      audioDuration: value['audioDuration'] != null
          ? Duration(milliseconds: safeParseInt(value['audioDuration']))
          : null,
      title: value['title'] ?? '',
      artist: value['artist'] ?? '',
      author: value['author'] ?? '',
      album: value['album'] ?? '',
      albumArtist: value['albumArtist'] ?? '',
      date:
          (value['date'] ?? '') != '' ? DateTime.tryParse(value['date']) : null,
      isOptimizedForStreaming: value['isOptimizedForStreaming'] as bool?,
      gpsCoordinates: value['latitude'] != null && value['longitude'] != null
          ? GpsCoordinates(
              latitude: safeParseDouble(value['latitude']),
              longitude: safeParseDouble(value['longitude']),
            )
          : null,
      frameRate: value['frameRate'] as double?,
      cameraMake: value['cameraMake'] ?? '',
      cameraModel: value['cameraModel'] ?? '',
    );
  }

  /// The title of the video (e.g., the name of the movie or video).
  final String title;

  /// The artist associated with the video (e.g., the creator or performer).
  final String artist;

  /// The author of the video content.
  final String author;

  /// The album the video belongs to (if applicable).
  final String album;

  /// The album artist, typically used when the album contains works from
  /// multiple artists.
  final String albumArtist;

  /// The date when the video was created or released.
  final DateTime? date;

  /// The size of the video file in bytes.
  final int fileSize;

  /// The effective display resolution of the video, represented as a [Size]
  /// object.
  ///
  /// This represents the actual dimensions as the video appears when played,
  /// with any rotation already accounted for.
  ///
  /// To retrieve the raw resolution before rotation correction,
  /// use [rawResolution].
  ///
  /// Example:
  /// ```dart
  /// Size(1080, 1920) // Portrait Full HD video
  /// ```
  final Size resolution;

  /// The raw resolution of the video before rotation is applied.
  ///
  /// This represents the actual pixel dimensions stored in the video file,
  /// regardless of how it appears when played. For rotated videos (90° or
  /// 270°), this will have width and height swapped compared to [resolution].
  ///
  /// Example:
  /// ```dart
  /// // For a portrait video with 90° rotation:
  /// resolution    // Size(1080, 1920) - what you see
  /// rawResolution // Size(1920, 1080) - what's stored
  /// ```
  Size get rawResolution {
    final isRotated90Or270 = rotation % 180 != 0;
    return isRotated90Or270 ? resolution.flipped : resolution;
  }

  /// The rotation of the video.
  final int rotation;

  /// The duration of the video.
  ///
  /// Example:
  /// ```dart
  /// Duration(seconds: 120) // 2 minutes
  /// ```
  final Duration duration;

  /// The duration of the audio track, if present.
  ///
  /// This value may differ from [duration] in cases where the audio track
  /// is shorter than the video. If the video has no audio track, this will
  /// be `null`.
  ///
  /// Example:
  /// ```dart
  /// Duration(seconds: 115) // Audio ends 5 seconds before video
  /// ```
  final Duration? audioDuration;

  /// The format of the video file, such as "mp4" or "avi".
  final String extension;

  /// The bitrate of the video in bits per second.
  ///
  /// This value represents the amount of data processed per unit of time in
  /// the video stream.
  /// Higher bitrate generally result in better video quality, but also
  /// larger file sizes.
  final int bitrate;

  /// Whether the video is optimized for progressive streaming.
  ///
  /// When `true`, the video's metadata (moov atom) is located at the beginning
  /// of the file, allowing browsers and media players to start playback before
  /// the entire file is downloaded.
  ///
  /// When `false`, the metadata is at the end of the file (mdat before moov),
  /// which requires downloading the entire file before playback can begin.
  ///
  /// This value is `null` for non-MP4/MOV formats or if the check couldn't
  /// be performed.
  ///
  /// To create streaming-optimized videos, set `shouldOptimizeForNetworkUse`
  /// to `true` when rendering.
  final bool? isOptimizedForStreaming;

  /// The GPS coordinates where the video was recorded.
  ///
  /// This value is `null` if the video does not contain location metadata
  /// or if the device did not have location permissions when recording.
  ///
  /// Example:
  /// ```dart
  /// GpsCoordinates(latitude: 47.3769, longitude: 8.5417) // Zurich, Switzerland
  /// ```
  final GpsCoordinates? gpsCoordinates;

  /// The frame rate of the video in frames per second (fps).
  ///
  /// This value represents how many frames are displayed per second.
  /// Common values are 24, 25, 30, 60 fps.
  ///
  /// Example:
  /// ```dart
  /// 30.0 // 30 fps
  /// ```
  final double? frameRate;

  /// The make (manufacturer) of the camera used to record the video.
  ///
  /// Example:
  /// ```dart
  /// 'Apple' // iPhone
  /// 'Samsung' // Samsung phone
  /// ```
  final String cameraMake;

  /// The model of the camera used to record the video.
  ///
  /// Example:
  /// ```dart
  /// 'iPhone 14 Pro'
  /// 'SM-S918B' // Samsung Galaxy S23 Ultra
  /// ```
  final String cameraModel;

  /// Returns a copy of this config with the given fields replaced.
  VideoMetadata copyWith({
    String? title,
    String? artist,
    String? author,
    String? album,
    String? albumArtist,
    DateTime? date,
    int? fileSize,
    Size? resolution,
    int? rotation,
    Duration? duration,
    Duration? audioDuration,
    String? extension,
    int? bitrate,
    bool? isOptimizedForStreaming,
    GpsCoordinates? gpsCoordinates,
    double? frameRate,
    String? cameraMake,
    String? cameraModel,
  }) {
    return VideoMetadata(
      title: title ?? this.title,
      artist: artist ?? this.artist,
      author: author ?? this.author,
      album: album ?? this.album,
      albumArtist: albumArtist ?? this.albumArtist,
      date: date ?? this.date,
      fileSize: fileSize ?? this.fileSize,
      resolution: resolution ?? this.resolution,
      rotation: rotation ?? this.rotation,
      duration: duration ?? this.duration,
      audioDuration: audioDuration ?? this.audioDuration,
      extension: extension ?? this.extension,
      bitrate: bitrate ?? this.bitrate,
      isOptimizedForStreaming:
          isOptimizedForStreaming ?? this.isOptimizedForStreaming,
      gpsCoordinates: gpsCoordinates ?? this.gpsCoordinates,
      frameRate: frameRate ?? this.frameRate,
      cameraMake: cameraMake ?? this.cameraMake,
      cameraModel: cameraModel ?? this.cameraModel,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is VideoMetadata &&
        other.title == title &&
        other.artist == artist &&
        other.author == author &&
        other.album == album &&
        other.albumArtist == albumArtist &&
        other.date == date &&
        other.fileSize == fileSize &&
        other.resolution == resolution &&
        other.rotation == rotation &&
        other.duration == duration &&
        other.audioDuration == audioDuration &&
        other.extension == extension &&
        other.bitrate == bitrate &&
        other.isOptimizedForStreaming == isOptimizedForStreaming &&
        other.gpsCoordinates == gpsCoordinates &&
        other.frameRate == frameRate &&
        other.cameraMake == cameraMake &&
        other.cameraModel == cameraModel;
  }

  @override
  int get hashCode {
    return title.hashCode ^
        artist.hashCode ^
        author.hashCode ^
        album.hashCode ^
        albumArtist.hashCode ^
        date.hashCode ^
        fileSize.hashCode ^
        resolution.hashCode ^
        rotation.hashCode ^
        duration.hashCode ^
        audioDuration.hashCode ^
        extension.hashCode ^
        bitrate.hashCode ^
        isOptimizedForStreaming.hashCode ^
        gpsCoordinates.hashCode ^
        frameRate.hashCode ^
        cameraMake.hashCode ^
        cameraModel.hashCode;
  }
}
