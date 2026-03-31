import 'dart:ui';

/// Pre-defined video quality presets for common export scenarios.
///
/// Each preset defines standard resolution and bitrate combinations optimized
/// for different use cases, from high-quality 4K exports to web-optimized
/// low-quality videos.
enum VideoQualityPreset {
  /// Ultra High Definition (3840x2160)
  ///
  /// Best for: Professional content, theatrical displays
  /// - Resolution: 3840x2160
  /// - Bitrate: 45 Mbps
  ultra4K(bitrate: 45000000, resolution: Size(3840, 2160)),

  /// 4K resolution (3840x2160)
  ///
  /// Best for: High-quality content, large screens
  /// - Resolution: 3840x2160
  /// - Bitrate: 35 Mbps
  k4(bitrate: 35000000, resolution: Size(3840, 2160)),

  /// Full HD High Quality (1920x1080)
  ///
  /// Best for: High-quality social media, YouTube
  /// - Resolution: 1920x1080
  /// - Bitrate: 16 Mbps
  p1080High(bitrate: 16000000, resolution: Size(1920, 1080)),

  /// Full HD Standard Quality (1920x1080)
  ///
  /// Best for: Standard social media, streaming
  /// - Resolution: 1920x1080
  /// - Bitrate: 8 Mbps
  p1080(bitrate: 8000000, resolution: Size(1920, 1080)),

  /// HD High Quality (1280x720)
  ///
  /// Best for: Social media stories, streaming
  /// - Resolution: 1280x720
  /// - Bitrate: 5 Mbps
  p720High(bitrate: 5000000, resolution: Size(1280, 720)),

  /// HD Standard Quality (1280x720)
  ///
  /// Best for: Mobile viewing, web uploads
  /// - Resolution: 1280x720
  /// - Bitrate: 3 Mbps
  p720(bitrate: 3000000, resolution: Size(1280, 720)),

  /// Standard Definition (854x480)
  ///
  /// Best for: Fast uploads, limited bandwidth
  /// - Resolution: 854x480
  /// - Bitrate: 2.5 Mbps
  p480(bitrate: 2500000, resolution: Size(854, 480)),

  /// Low Quality (640x360)
  ///
  /// Best for: Preview videos, very limited bandwidth
  /// - Resolution: 640x360
  /// - Bitrate: 1 Mbps
  low(bitrate: 1000000, resolution: Size(640, 360)),

  /// Custom quality (user-defined settings)
  ///
  /// Use this when you want to specify your own bitrate and resolution
  custom(bitrate: 8000000);

  const VideoQualityPreset({required this.bitrate, this.resolution});

  /// The bitrate in bits per second for this preset.
  ///
  /// For [VideoQualityPreset.custom], defaults to 8 Mbps.
  final int bitrate;

  /// The target resolution for this preset.
  ///
  /// For [VideoQualityPreset.custom], returns null to keep original resolution.
  final Size? resolution;

  /// Returns a human-readable description of this preset.
  String get description {
    switch (this) {
      case VideoQualityPreset.ultra4K:
        return 'Ultra HD 4K (3840x2160, 45 Mbps)';
      case VideoQualityPreset.k4:
        return '4K (3840x2160, 35 Mbps)';
      case VideoQualityPreset.p1080High:
        return 'Full HD High (1920x1080, 16 Mbps)';
      case VideoQualityPreset.p1080:
        return 'Full HD (1920x1080, 8 Mbps)';
      case VideoQualityPreset.p720High:
        return 'HD High (1280x720, 5 Mbps)';
      case VideoQualityPreset.p720:
        return 'HD (1280x720, 3 Mbps)';
      case VideoQualityPreset.p480:
        return 'SD (854x480, 2.5 Mbps)';
      case VideoQualityPreset.low:
        return 'Low (640x360, 1 Mbps)';
      case VideoQualityPreset.custom:
        return 'Custom';
    }
  }
}
