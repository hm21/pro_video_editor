import AVFoundation
import Foundation

/// Cuts a clip range back to where an asset's video and audio tracks both
/// still have content.
///
/// A source asset's two tracks routinely end tens of milliseconds apart,
/// because capture and export stop them independently. A range that spans the
/// longer track ends on missing audio — the seam a looping player replays
/// every cycle. At the other end, `mediaTimeRange(of:)` skips the short
/// delay some muxers open the video track with.
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

  /// How late a video track's first frame may start before the delay counts
  /// as the source's own content rather than a muxer artifact.
  ///
  /// A muxer that moves AAC priming out of the audio track pushes the video
  /// back by the same amount instead, so ffmpeg-transcoded mp4s commonly open
  /// their video with a 21–23 ms empty edit (`divine_transcribed.mp4` does).
  /// A file without an edit list starts its first frame late by its B-frame
  /// delay instead, two frames for x264 (`fragmented_b_frames.mp4`). An
  /// intentionally late start lasts longer than this.
  static let maxLateStart = CMTime(value: 100, timescale: 1000)

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

  /// The part of the track's time range that holds frames: the range from
  /// its first frame on, when that frame starts at most `maxLateStart` late.
  ///
  /// AVFoundation folds a leading empty edit into the track's duration rather
  /// than into its start, and a file without an edit list maps its media from
  /// zero even where B-frames hold its first frame back, so `timeRange(of:)`
  /// still begins at zero. A clip inserted from there has no frame until the
  /// first one starts, and the compositor fills that gap with a black frame at
  /// the clip's start.
  static func mediaTimeRange(of track: AVAssetTrack) async -> CMTimeRange {
    let range = await timeRange(of: track)
    let end = CMTimeRangeGetEnd(range)
    let mediaStart = await lateStart(of: track)
    guard mediaStart > range.start, mediaStart < end else { return range }
    return CMTimeRange(start: mediaStart, end: end)
  }

  /// Where the track's first frame starts when a short delay holds it back:
  /// the empty edits before its first media edit, plus the time that edit
  /// runs before its first frame. Zero when the track opens with a frame or
  /// with a longer delay.
  private static func lateStart(of track: AVAssetTrack) async -> CMTime {
    let segments: [AVAssetTrackSegment]
    if #available(iOS 15.0, macOS 13.0, *) {
      segments = (try? await track.load(.segments)) ?? track.segments
    } else {
      segments = track.segments
    }
    guard let media = segments.first(where: { !$0.isEmpty }) else { return .zero }
    let start = media.timeMapping.target.start + (await firstFrameDelay(in: media, of: track))
    guard start.isNumeric, start > .zero, start <= maxLateStart else { return .zero }
    return start
  }

  /// How far into `segment` its first frame starts, in track time.
  ///
  /// An edit list starts its edit at the first frame, but a file without one
  /// maps its media from zero, before B-frames let the first frame start.
  /// Zero where the OS cannot look a frame up by its time.
  private static func firstFrameDelay(
    in segment: AVAssetTrackSegment, of track: AVAssetTrack
  ) async -> CMTime {
    let source = segment.timeMapping.source
    guard #available(iOS 16.0, macOS 13.0, *),
      (try? await track.load(.canProvideSampleCursors)) == true,
      // The last frame starting at or before the edit, else the first after.
      let cursor = track.makeSampleCursor(presentationTimeStamp: source.start)
    else { return .zero }
    let delay = cursor.presentationTimeStamp - source.start
    guard delay.isNumeric, delay > .zero, source.duration > .zero else { return .zero }
    // An edit that plays its media at another rate scales the delay alike.
    let target = segment.timeMapping.target
    return target.duration == source.duration
      ? delay : CMTimeMultiplyByFloat64(delay, multiplier: target.duration.seconds / source.duration.seconds)
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
