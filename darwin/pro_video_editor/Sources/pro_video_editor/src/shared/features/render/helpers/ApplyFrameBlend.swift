import AVFoundation
import CoreImage
import Foundation

/// A frame-blended clip's span on the composition timeline and where each
/// moment of it falls between two source frames.
///
/// The composition asks for a frame every `frameDuration`; on a stretch the
/// clip plays slowed down, the source frame shown then is held for several of
/// them. Mixing it with the next source frame by how far the moment lies
/// between the two keeps the motion going instead. Stretches at about the
/// source's speed or faster show their frames as they are.
///
/// `startUs..<endUs` is the clip's span in composition microseconds, before
/// any render-wide speed. Single-track path only. Mirrors `FrameBlendSchedule`
/// on Android.
struct FrameBlendWindow: Sendable {
  let startUs: Int64
  let endUs: Int64
  /// The time in the file that plays at `startUs`.
  let sourceStartUs: Int64
  /// How much of the file the clip plays.
  let sourceDurationUs: Int64
  /// The file's frame duration.
  let frameUs: Double
  /// The time in the file of its first frame, where the frame grid starts.
  let firstFrameUs: Int64
  /// The clip's constant speed, when it has no ramp.
  let speed: Double
  let ramp: SpeedRamp?

  /// A moment this close to a source frame, as a share of the way to the
  /// next, shows that source frame alone, as on Android. Here it also keeps
  /// a moment on a frame boundary, which AVFoundation may round to either
  /// frame, from mixing in the frame after the one it shows.
  static let snap = 1.0 / 32.0

  /// A stretch at this speed or faster is not blended, as on Android: the
  /// source frames lie at most 16/15 of a frame apart.
  static let minimumUnblendedSpeed = 15.0 / 16.0

  /// How far the moment at composition time `tUs` lies from the source frame
  /// the video shows then towards the next one, or `nil` where that frame is
  /// shown as it is: outside the clip, on a stretch that is not slowed down,
  /// or right on a source frame.
  func weight(atCompositionUs tUs: Int64) -> Double? {
    guard frameUs > 0, tUs >= startUs, tUs < endUs else { return nil }
    let (played, speed) = playedSourceUs(atOutputUs: Double(tUs - startUs))
    guard speed < Self.minimumUnblendedSpeed else { return nil }
    let sourceUs = Double(sourceStartUs) + min(max(played, 0), Double(sourceDurationUs))
    let position = (sourceUs - Double(firstFrameUs)) / frameUs
    let weight = position - position.rounded(.down)
    if weight <= Self.snap || weight >= 1 - Self.snap { return nil }
    return weight
  }

  /// How much of the window has played after `outputUs` of the clip's own
  /// output, and the speed it plays at there.
  private func playedSourceUs(atOutputUs outputUs: Double) -> (Double, Double) {
    guard let ramp else { return (outputUs * speed, speed) }
    let total = Double(sourceDurationUs)
    var elapsed = 0.0
    for step in ramp.steps {
      let length = (step.end - step.start) * total
      let output = length / step.speed
      if outputUs < elapsed + output {
        return (step.start * total + (outputUs - elapsed) * step.speed, step.speed)
      }
      elapsed += output
    }
    return (total, ramp.steps.last?.speed ?? 1)
  }
}

/// One window per frame-blended clip that slows down somewhere, from the
/// per-clip instructions. A reversed clip is skipped: its frames play in the
/// order opposite to the one the window counts them in.
func computeFrameBlendWindows(
  videoClips: [VideoClip], clipInstructions: [ClipInstruction]
) -> [FrameBlendWindow] {
  var windows: [FrameBlendWindow] = []
  for (index, clip) in videoClips.enumerated() {
    guard index < clipInstructions.count, clip.frameBlending, clip.slowsDown else { continue }
    if clip.reverseVideo {
      PluginLog.print(
        "[\(Tags.render)] ⚠️ Clip \(index): frame blending is not supported in reverse and is skipped"
      )
      continue
    }
    let instruction = clipInstructions[index]
    let frameSeconds = instruction.sourceFrameDuration.seconds
    guard frameSeconds.isFinite, frameSeconds > 0 else { continue }
    let outputUs = Double(blendMicroseconds(instruction.timeRange.duration))
    let speed = Double(clip.playbackSpeed.flatMap { $0 > 0 ? $0 : nil } ?? 1)
    let sourceDurationUs: Int64
    if let ramp = clip.speedRamp, ramp.durationFactor > 0 {
      sourceDurationUs = Int64((outputUs / ramp.durationFactor).rounded())
    } else {
      sourceDurationUs = Int64((outputUs * speed).rounded())
    }
    windows.append(
      FrameBlendWindow(
        startUs: blendMicroseconds(instruction.timeRange.start),
        endUs: blendMicroseconds(CMTimeRangeGetEnd(instruction.timeRange)),
        sourceStartUs: blendMicroseconds(instruction.sourceStart),
        sourceDurationUs: sourceDurationUs,
        frameUs: frameSeconds * 1_000_000,
        firstFrameUs: blendMicroseconds(instruction.sourceFirstFrame),
        speed: speed,
        ramp: clip.speedRamp))
  }
  return windows
}

/// Adds a composition track that shows, at every moment of a frame-blended
/// clip, the source frame after the one `videoTrack` shows, so the compositor
/// receives both frames a moment mixes.
///
/// Each stretch of `videoTrack` inside a window is inserted again from one
/// source frame later, onto the same span and scaled the same way. The clip's
/// last frame has no later frame of the clip to mix with: the frame after it,
/// which the clip's end or the file's cut off, is left out, so the track is
/// empty there and that last frame is held, as on Android.
///
/// Call before any render-wide speed change, which then scales this track
/// with the rest.
///
/// - Returns: The new track's id, or `nil` without windows.
func applyFrameBlendTrack(
  composition: AVMutableComposition,
  videoTrack: AVMutableCompositionTrack,
  windows: [FrameBlendWindow]
) async throws -> CMPersistentTrackID? {
  guard !windows.isEmpty else { return nil }
  guard
    let next = composition.addMutableTrack(
      withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
  else {
    throw NSError(
      domain: "FrameBlend", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Failed to add the frame blend track"])
  }

  let segments = videoTrack.segments.filter { !$0.isEmpty }
  // Holds the assets as well: a track whose asset is gone can no longer be
  // inserted (-11800).
  var sourceTracks: [String: (asset: AVURLAsset, track: AVAssetTrack, end: CMTime)] = [:]
  var end = CMTime.zero

  for window in windows {
    let span = CMTimeRange(
      start: CMTime(value: window.startUs, timescale: 1_000_000),
      end: CMTime(value: window.endUs, timescale: 1_000_000))
    let frame = CMTime(seconds: window.frameUs / 1_000_000, preferredTimescale: 1_000_000)

    // The stretches of the video track inside the clip.
    let parts = segments.compactMap { segment -> (AVCompositionTrackSegment, CMTimeRange)? in
      let part = segment.timeMapping.target.intersection(span)
      return part.duration > .zero ? (segment, part) : nil
    }
    // The next frames stop where the frame after the clip's last one starts,
    // so that last frame is held rather than mixed with one the clip's end
    // cut off.
    let clipSourceEndUs =
      parts.map { segment, part in
        let target = segment.timeMapping.target
        let mapped = segment.timeMapping.source
        let ratio = mapped.duration.seconds / target.duration.seconds
        return (mapped.start.seconds + (part.end - target.start).seconds * ratio) * 1_000_000
      }.max() ?? 0
    let lastFrameEnd = CMTime(
      value: Int64(
        frameBoundaryUs(
          atOrAfter: clipSourceEndUs, firstFrameUs: Double(window.firstFrameUs),
          frameUs: window.frameUs
        ).rounded(.down)),
      timescale: 1_000_000)

    for (segment, part) in parts {
      let target = segment.timeMapping.target
      guard let url = segment.sourceURL else { continue }

      let key = "\(url.absoluteString)#\(segment.sourceTrackID)"
      if sourceTracks[key] == nil {
        let asset = AVURLAsset(url: url)
        guard let track = try await loadSourceTrack(asset: asset, id: segment.sourceTrackID)
        else { continue }
        let range: CMTimeRange
        if #available(iOS 15.0, macOS 12.0, *) {
          range = try await track.load(.timeRange)
        } else {
          range = track.timeRange
        }
        sourceTracks[key] = (asset, track, CMTimeRangeGetEnd(range))
      }
      guard let source = sourceTracks[key] else { continue }

      // The source behind `part`, a frame later, cut where the clip's last
      // frame or the file ends.
      let mapped = segment.timeMapping.source
      let ratio = mapped.duration.seconds / target.duration.seconds
      let start =
        mapped.start + CMTimeMultiplyByFloat64(part.start - target.start, multiplier: ratio)
        + frame
      let sourceEnd = CMTimeMinimum(
        CMTimeMinimum(
          start + CMTimeMultiplyByFloat64(part.duration, multiplier: ratio), source.end),
        lastFrameEnd)
      guard sourceEnd > start else { continue }
      let sourceRange = CMTimeRange(start: start, end: sourceEnd)
      let shownFor = CMTimeMinimum(
        CMTimeMultiplyByFloat64(sourceRange.duration, multiplier: 1 / ratio), part.duration)

      // Inserting before the track's end would push what follows later.
      let at = part.start > end ? part.start : end
      if at > end {
        next.insertEmptyTimeRange(CMTimeRange(start: end, end: at))
      }
      try next.insertTimeRange(sourceRange, of: source.track, at: at)
      if sourceRange.duration != shownFor {
        next.scaleTimeRange(
          CMTimeRange(start: at, duration: sourceRange.duration), toDuration: shownFor)
      }
      end = at + shownFor
    }
  }
  PluginLog.print(
    "[\(Tags.render)] 🎞️ Frame blending: \(windows.count) clip(s), next frames on track \(next.trackID)"
  )
  return next.trackID
}

/// The start of the first source frame at or after `timeUs`, on the grid of
/// `frameUs` steps from `firstFrameUs`: the end of the last frame a clip cut
/// at `timeUs` shows. A frame the clip reaches into by no more than
/// `FrameBlendWindow.snap` of it does not count, since no moment shows it.
func frameBoundaryUs(atOrAfter timeUs: Double, firstFrameUs: Double, frameUs: Double)
  -> Double
{
  guard frameUs > 0, timeUs.isFinite else { return timeUs }
  let steps = ((timeUs - firstFrameUs) / frameUs - FrameBlendWindow.snap).rounded(.up)
  return firstFrameUs + max(steps, 0) * frameUs
}

/// `image` mixed `weight` of the way towards `next`, on their values as they
/// are: the compositor's context has no working color space, so this is the
/// same mix as the Android shader's.
func blendFrames(_ image: CIImage, _ next: CIImage, weight: Double) -> CIImage {
  guard let dissolve = CIFilter(name: "CIDissolveTransition") else { return image }
  dissolve.setValue(image, forKey: kCIInputImageKey)
  dissolve.setValue(next, forKey: kCIInputTargetImageKey)
  dissolve.setValue(weight, forKey: kCIInputTimeKey)
  return dissolve.outputImage?.cropped(to: image.extent) ?? image
}

private func loadSourceTrack(asset: AVURLAsset, id: CMPersistentTrackID) async throws
  -> AVAssetTrack?
{
  if #available(iOS 15.0, macOS 12.0, *) {
    return try await asset.loadTrack(withTrackID: id)
  }
  return asset.track(withTrackID: id)
}

private func blendMicroseconds(_ time: CMTime) -> Int64 {
  guard time.isValid, time.isNumeric else { return 0 }
  return nearestMicroseconds(time)
}
