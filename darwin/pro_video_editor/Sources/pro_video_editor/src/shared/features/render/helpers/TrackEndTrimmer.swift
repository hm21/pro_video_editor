import AVFoundation
import Foundation

/// Cuts a clip range back to where an asset's video and audio tracks both
/// still have content.
///
/// A source asset's two tracks routinely end tens of milliseconds apart,
/// because capture and export stop them independently. A range that spans the
/// longer track ends on missing audio — the seam a looping player replays
/// every cycle.
///
/// Both render paths that can honour `trimToCommonTrackEnd` go through here:
/// the composition path (`VideoSequenceBuilder`, per clip) and the lossless
/// bitrate-cap fast path (`RenderVideo.passthroughExport`, whole asset).
internal enum TrackEndTrimmer {

  /// How far a clip's audio may fall short of its video before the gap counts
  /// as content rather than a track-end mismatch.
  ///
  /// Capture and export pipelines end the two tracks a fraction of a second
  /// apart; a survey of published mp4s put the worst case at ~0.4 s. A larger
  /// gap means the clip is genuinely meant to outlast its audio, and trimming
  /// it would swallow content instead of a seam.
  static let maxTrackEndMismatch = CMTime(value: 500, timescale: 1000)

  /// The track's time range, loaded asynchronously where the OS supports it.
  static func timeRange(of track: AVAssetTrack) async -> CMTimeRange {
    #if os(iOS)
      if #available(iOS 15.0, *) {
        return (try? await track.load(.timeRange)) ?? track.timeRange
      }
    #elseif os(macOS)
      if #available(macOS 13.0, *) {
        return (try? await track.load(.timeRange)) ?? track.timeRange
      }
    #endif
    return track.timeRange
  }

  /// Returns `range` cut back to where `asset`'s audio track also has content,
  /// or `nil` when the range should be left as it is.
  ///
  /// - Parameters:
  ///   - range: The clip range, already clamped to the video track
  ///   - asset: The source asset `range` refers to
  ///   - label: Identifies the clip in the log line for a skipped trim
  /// - Returns: The trimmed range, or `nil` to keep `range` unchanged
  static func trimmedRange(
    _ range: CMTimeRange,
    in asset: AVAsset,
    label: String
  ) async -> CMTimeRange? {
    guard let audioTrack = try? await MediaInfoExtractor.loadAudioTrack(from: asset) else {
      return nil
    }

    // `CMTimeRangeGetIntersection` clamps both ends, but only the end moves in
    // practice: AVFoundation folds a leading empty edit into the track's
    // duration rather than into its start, so an audio track that begins late
    // still reports `timeRange.start == 0` and the clip keeps its head.
    let commonRange = CMTimeRangeGetIntersection(
      range, otherRange: await timeRange(of: audioTrack))
    let shortfall = CMTimeSubtract(range.duration, commonRange.duration)

    if commonRange.duration > .zero, shortfall <= maxTrackEndMismatch {
      return commonRange
    }

    if shortfall > maxTrackEndMismatch {
      // Too large to be an encoder tail: the clip genuinely outlasts its own
      // audio (stop motion held past a short sound, a source file with a
      // broken audio track). Trimming here would swallow content, so keep the
      // video and leave the tail alone.
      PluginLog.print(
        "   ⚠️ \(label) audio ends \(String(format: "%.2f", shortfall.seconds))s early — too far to treat as a track-end mismatch, not trimming"
      )
    }
    return nil
  }

  /// Returns the whole asset cut back to where both tracks still have content,
  /// or `nil` when it should be exported as it is.
  ///
  /// Mirrors what the composition path does for an untrimmed single clip:
  /// clamp to the video track first, then to the audio track.
  ///
  /// - Parameters:
  ///   - asset: The source asset to measure
  ///   - label: Identifies the asset in the log line for a skipped trim
  /// - Returns: The trimmed range, or `nil` to export the asset unchanged
  static func trimmedAssetRange(of asset: AVAsset, label: String) async -> CMTimeRange? {
    guard let videoTrack = try? await MediaInfoExtractor.loadVideoTrack(from: asset) else {
      return nil
    }

    let assetDuration: CMTime
    if #available(iOS 15.0, macOS 13.0, *) {
      assetDuration = (try? await asset.load(.duration)) ?? .zero
    } else {
      assetDuration = asset.duration
    }

    // Some MP4 files have a container duration slightly longer than the video
    // track's decoded frames; clamp to the track before consulting the audio.
    let rawRange = CMTimeRange(start: .zero, duration: assetDuration)
    let clamped = CMTimeRangeGetIntersection(
      rawRange, otherRange: await timeRange(of: videoTrack))
    let videoRange = clamped.duration > .zero ? clamped : rawRange

    return await trimmedRange(videoRange, in: asset, label: label)
  }
}
