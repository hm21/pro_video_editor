import AVFoundation
import Foundation

/// Creates the stage of every custom effect of a render, asking each
/// registered factory for a renderer.
///
/// - Throws: when nothing is registered under an effect's id, so the render
///   fails before it starts instead of exporting without the effect.
func makeCustomVideoEffectStages(_ effects: [CustomVideoEffectConfig]) throws
  -> [CustomVideoEffectStage]
{
  try effects.map { effect in
    guard let factory = CustomVideoEffects.factory(for: effect.id) else {
      throw NSError(
        domain: "CustomVideoEffects", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "No custom video effect is registered under \"\(effect.id)\""
        ])
    }
    return CustomVideoEffectStage(config: effect, renderer: factory(effect.params))
  }
}

/// Gives every custom effect that asks for earlier frames a composition track
/// per offset, showing the video that far back, and adds those tracks to the
/// instructions so the compositor receives their frames.
///
/// The compositor only ever gets source frames at the time it is asked for,
/// and AVFoundation may ask for frames out of order, so earlier frames cannot
/// come from what it drew before. A copy of the video track delayed by the
/// offset hands it exactly the frame that far back, whatever order the frames
/// are asked for in, during export and playback alike.
///
/// Each copy only repeats a clip within that same clip: for the first
/// `offset` of every clip it is empty, so a clip never sees the one before it.
///
/// Call after every speed change is applied, so the offsets are measured on
/// the rendered video.
///
/// - Parameters:
///   - stages: The render's custom effects; their `historyTrackIDs` are set.
///   - composition: The composition holding the video track.
///   - videoTrackID: The single-track path's video track.
///   - instructions: One instruction per clip, spanning the clip.
/// - Returns: The instructions, requiring the delayed tracks too.
func applyCustomVideoEffectHistory(
  stages: [CustomVideoEffectStage],
  composition: AVMutableComposition,
  videoTrackID: CMPersistentTrackID,
  instructions: [AVVideoCompositionInstructionProtocol]
) async throws -> [AVVideoCompositionInstructionProtocol] {
  let offsets = Set(stages.flatMap { $0.historyOffsetsUs }.filter { $0 > 0 }).sorted()
  guard !offsets.isEmpty else { return instructions }
  guard let videoTrack = composition.track(withTrackID: videoTrackID) else {
    throw NSError(
      domain: "CustomVideoEffects", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "The video track to delay is missing"])
  }

  let clipRanges = instructions.map { $0.timeRange }
  let segments = videoTrack.segments.filter { !$0.isEmpty }
  var sourceTracks = SourceTrackCache()
  var trackIDs: [Int64: CMPersistentTrackID] = [:]

  for offsetUs in offsets {
    guard
      let delayed = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      throw NSError(
        domain: "CustomVideoEffects", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Failed to add a delayed video track"])
    }
    let offset = CMTime(value: offsetUs, timescale: 1_000_000)
    var end = CMTime.zero

    for clip in clipRanges {
      // The part of the clip a frame `offset` later, still in the clip, shows.
      let shown = CMTimeRange(start: clip.start, end: CMTimeRangeGetEnd(clip) - offset)
      guard shown.duration > .zero else { continue }

      for segment in segments {
        let target = segment.timeMapping.target
        let part = target.intersection(shown)
        guard part.duration > .zero, let url = segment.sourceURL else { continue }

        // Map the part back onto the segment's source, which a speed change
        // made longer or shorter than its place on the timeline.
        let source = segment.timeMapping.source
        let ratio = source.duration.seconds / target.duration.seconds
        let sourceRange = CMTimeRange(
          start: source.start + CMTimeMultiplyByFloat64(part.start - target.start, multiplier: ratio),
          duration: CMTimeMultiplyByFloat64(part.duration, multiplier: ratio))

        // Inserting before the track's end would push what follows later.
        let shifted = part.start + offset
        let at = shifted > end ? shifted : end
        if at > end {
          delayed.insertEmptyTimeRange(CMTimeRange(start: end, end: at))
        }
        let assetTrack = try await sourceTracks.track(url: url, id: segment.sourceTrackID)
        try delayed.insertTimeRange(sourceRange, of: assetTrack, at: at)
        if sourceRange.duration != part.duration {
          delayed.scaleTimeRange(
            CMTimeRange(start: at, duration: sourceRange.duration), toDuration: part.duration)
        }
        end = at + part.duration
      }
    }
    trackIDs[offsetUs] = delayed.trackID
    PluginLog.print(
      "🪞 Custom effects: video delayed by \(offsetUs / 1000) ms on track \(delayed.trackID)")
  }

  for stage in stages {
    stage.historyTrackIDs = stage.historyOffsetsUs.map {
      trackIDs[$0] ?? kCMPersistentTrackID_Invalid
    }
  }
  let delayedIDs = offsets.compactMap { trackIDs[$0] }
  return instructions.map { instruction in
    guard let custom = instruction as? CustomVideoCompositionInstruction, !custom.isLayered
    else { return instruction }
    return custom.addingHistoryTracks(delayedIDs)
  }
}

/// The source asset tracks the delayed copies insert from, loaded once each.
///
/// Holds on to the assets as well: a track whose asset is gone can no longer
/// be inserted, and fails with an unknown AVFoundation error (-11800).
private struct SourceTrackCache {
  private var tracks: [String: AVAssetTrack] = [:]
  private var assets: [URL: AVURLAsset] = [:]

  mutating func track(url: URL, id: CMPersistentTrackID) async throws -> AVAssetTrack {
    let key = "\(url.absoluteString)#\(id)"
    if let track = tracks[key] { return track }
    let asset = assets[url] ?? AVURLAsset(url: url)
    assets[url] = asset
    let loaded: AVAssetTrack?
    if #available(iOS 15.0, macOS 12.0, *) {
      loaded = try await asset.loadTrack(withTrackID: id)
    } else {
      loaded = asset.track(withTrackID: id)
    }
    guard let track = loaded else {
      throw NSError(
        domain: "CustomVideoEffects", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Missing source track \(id) in \(url.lastPathComponent)"])
    }
    tracks[key] = track
    return track
  }
}
