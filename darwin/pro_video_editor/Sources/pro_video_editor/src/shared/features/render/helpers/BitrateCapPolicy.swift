import Foundation

/// Decides how a requested bitrate cap is enforced on the render output,
/// mirroring the Android `BitrateCapPolicy`.
///
/// The requested bitrate is a guaranteed *maximum* for the rendered output:
/// - A single no-edit clip already within cap × tolerance is remuxed
///   losslessly (`AVAssetExportPresetPassthrough`) instead of re-encoded.
/// - Everything else renders through the `BitrateCappedExporter`
///   (AVAssetReader → AVAssetWriter), where `AVVideoAverageBitRateKey`
///   actually applies the cap — unlike `AVAssetExportSession` presets, which
///   pick their own bitrate.
internal enum BitrateCapPolicy {

  /// Sources up to cap × tolerance keep the lossless fast path. The headroom
  /// absorbs probe inaccuracy (the file-size fallback includes audio and
  /// container overhead) and encoder rate-control drift around the target.
  static let tolerance = 1.2

  /// Returns true when the video must be re-encoded to honor the cap.
  ///
  /// - Parameters:
  ///   - requestedBitrate: Requested maximum in bits per second, or nil when
  ///     no cap was requested (never forces encoding).
  ///   - sourceBitrates: Probed bitrate of each source video in bits per
  ///     second. A nil entry means the bitrate could not be determined — the
  ///     cap cannot be proven, so encoding is forced.
  ///   - tolerance: Multiplier on the cap below which a source counts as
  ///     compliant.
  static func shouldForceEncode(
    requestedBitrate: Int?,
    sourceBitrates: [Int64?],
    tolerance: Double = BitrateCapPolicy.tolerance
  ) -> Bool {
    guard let requestedBitrate = requestedBitrate else { return false }
    guard !sourceBitrates.isEmpty else { return false }
    let budget = Double(requestedBitrate) * tolerance
    return sourceBitrates.contains { rate in
      guard let rate = rate else { return true }
      return Double(rate) > budget
    }
  }

  /// True when the render has no edits at all, so a compliant source can be
  /// remuxed with `AVAssetExportPresetPassthrough` instead of re-encoded:
  /// exactly one clip, untrimmed, at original speed/volume, with no effects,
  /// no extra audio, and no output-geometry or frame-rate changes.
  static func isPassthroughEligible(_ config: RenderConfig) -> Bool {
    guard config.composition == nil,
      config.videoClips.count == 1,
      config.imageLayers.isEmpty,
      config.colorFilters.isEmpty,
      config.audioTracks.isEmpty,
      config.enableAudio,
      config.rotateTurns == nil || config.rotateTurns == 0,
      !config.flipX, !config.flipY,
      config.cropWidth == nil, config.cropHeight == nil,
      config.cropX == nil, config.cropY == nil,
      config.scaleX == nil || config.scaleX == 1.0,
      config.scaleY == nil || config.scaleY == 1.0,
      config.outputWidth == nil, config.outputHeight == nil,
      config.maxFrameRate == nil,
      config.playbackSpeed == nil || config.playbackSpeed == 1.0,
      config.blur == nil || config.blur == 0,
      config.chromaKey == nil,
      config.startUs == nil, config.endUs == nil
    else { return false }

    let clip = config.videoClips[0]
    return (clip.startUs == nil || clip.startUs == 0)
      && clip.endUs == nil
      && (clip.volume == nil || clip.volume == 1.0)
      && (clip.playbackSpeed == nil || clip.playbackSpeed == 1.0)
      && !clip.reverseVideo
      && clip.chromaKey == nil
  }
}
