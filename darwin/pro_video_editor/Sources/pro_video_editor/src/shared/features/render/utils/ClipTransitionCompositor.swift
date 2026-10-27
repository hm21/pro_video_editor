import AVFoundation
import CoreImage
import Foundation

/// The instruction `ClipTransitionRenderer` hands ``ClipTransitionCompositor``
/// for a transition drawn by ``ClipTransitionEffects``: which track carries
/// which clip, how to turn each upright, and the transition to draw.
///
/// Everything the compositor needs travels here rather than in shared state,
/// so concurrent renders cannot see each other's transition.
internal final class ClipTransitionInstruction: NSObject, AVVideoCompositionInstructionProtocol,
  @unchecked Sendable
{
  let timeRange: CMTimeRange
  let enablePostProcessing: Bool = false
  let containsTweening: Bool = true
  let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

  let outgoingTrackID: CMPersistentTrackID
  let incomingTrackID: CMPersistentTrackID
  /// Each track's preferred transform, which turns its frames upright.
  let outgoingTransform: CGAffineTransform
  let incomingTransform: CGAffineTransform
  let type: String
  let direction: String
  let curve: String
  /// The composition's frame duration, so the last frame lands on progress 1
  /// as Android's last frame does.
  let frameDuration: CMTime
  /// Each side's keyframed motion, or nil when it stays where it is.
  let outgoingMotion: TransitionSideMotion?
  let incomingMotion: TransitionSideMotion?

  var requiredSourceTrackIDs: [NSValue]? {
    [NSNumber(value: outgoingTrackID), NSNumber(value: incomingTrackID)]
  }

  init(
    timeRange: CMTimeRange,
    outgoingTrackID: CMPersistentTrackID, incomingTrackID: CMPersistentTrackID,
    outgoingTransform: CGAffineTransform, incomingTransform: CGAffineTransform,
    type: String, direction: String, curve: String, frameDuration: CMTime,
    outgoingMotion: TransitionSideMotion? = nil, incomingMotion: TransitionSideMotion? = nil
  ) {
    self.timeRange = timeRange
    self.outgoingTrackID = outgoingTrackID
    self.incomingTrackID = incomingTrackID
    self.outgoingTransform = outgoingTransform
    self.incomingTransform = incomingTransform
    self.type = type
    self.direction = direction
    self.curve = curve
    self.frameDuration = frameDuration
    self.outgoingMotion = outgoingMotion
    self.incomingMotion = incomingMotion
    super.init()
  }

  /// Linear progress of the frame at `time`: 0 on the first frame, 1 on the
  /// last, which starts one frame before the end.
  func linearProgress(at time: CMTime) -> Double {
    let elapsed = CMTimeGetSeconds(CMTimeSubtract(time, timeRange.start))
    let span =
      CMTimeGetSeconds(timeRange.duration) - CMTimeGetSeconds(frameDuration)
    guard span > 0, elapsed.isFinite else { return 1 }
    return min(max(elapsed / span, 0), 1)
  }
}

/// One side's keyframed motion inside a pre-rendered blend.
///
/// The side's `sourceRange` of its file is stretched over the blend's
/// duration, so a moment of the blend maps linearly onto the source frame it
/// shows, which takes the motion of its own timestamp.
internal struct TransitionSideMotion: Sendable {
  let keyframes: [KeyframeConfig]
  let sourceStartUs: Int64
  let sourceDurationUs: Int64
  let blendDurationUs: Int64

  /// nil when there are no keyframes.
  init?(keyframes: [KeyframeConfig], sourceRange: CMTimeRange, blendDuration: CMTime) {
    guard !keyframes.isEmpty else { return nil }
    self.keyframes = keyframes
    sourceStartUs = Int64((CMTimeGetSeconds(sourceRange.start) * 1_000_000).rounded())
    sourceDurationUs = Int64((CMTimeGetSeconds(sourceRange.duration) * 1_000_000).rounded())
    blendDurationUs = Int64((CMTimeGetSeconds(blendDuration) * 1_000_000).rounded())
  }

  /// The motion of the frame shown `time` into the blend.
  func motion(at time: CMTime) -> FrameMotion? {
    let elapsedUs = CMTimeGetSeconds(time) * 1_000_000
    guard elapsedUs.isFinite, blendDurationUs > 0 else { return nil }
    let share = min(max(elapsedUs / Double(blendDurationUs), 0), 1)
    let sourceUs = sourceStartUs + Int64((share * Double(sourceDurationUs)).rounded())
    return segmentMotion(keyframes, atSourceUs: sourceUs)
  }
}

/// Draws one frame of a ``ClipTransitionInstruction``'s transition from the
/// two source frames, with ``ClipTransitionEffects``.
///
/// Reads and writes BGRA through a context without color management, like
/// `VideoCompositor`, so the transition clip's colors match the clips it sits
/// between once the main render reads it back.
internal final class ClipTransitionCompositor: NSObject, AVVideoCompositing {
  private let context = CIContext(options: [
    .workingColorSpace: NSNull(),
    .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
  ])

  var sourcePixelBufferAttributes: [String: any Sendable]? = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
  ]

  var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
  ]

  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
    // Intentional no-op: each request carries its own render context.
  }

  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    let size = request.renderContext.size
    let instruction = request.videoCompositionInstruction as? ClipTransitionInstruction
    // A track with a gap leaves the other clip to draw from, as a layer
    // instruction draws only the clips it has, rather than failing the
    // whole blend into a hard cut.
    let blendTime = instruction.map {
      CMTimeSubtract(request.compositionTime, $0.timeRange.start)
    }
    let outgoingFrame = instruction.flatMap {
      source(request, $0.outgoingTrackID, $0.outgoingTransform, size: size)
        .map { moved($0, by: instruction?.outgoingMotion, at: blendTime) }
    }
    let incomingFrame = instruction.flatMap {
      source(request, $0.incomingTrackID, $0.incomingTransform, size: size)
        .map { moved($0, by: instruction?.incomingMotion, at: blendTime) }
    }
    guard let instruction,
      let outgoing = outgoingFrame ?? incomingFrame,
      let incoming = incomingFrame ?? outgoingFrame,
      let target = request.renderContext.newPixelBuffer()
    else {
      request.finish(
        with: NSError(
          domain: "ClipTransitionCompositor", code: 0,
          userInfo: [
            NSLocalizedDescriptionKey: "A transition frame is missing its sources or an output buffer"
          ]))
      return
    }

    let linear = instruction.linearProgress(at: request.compositionTime)
    let durationUs = Int64(
      (CMTimeGetSeconds(instruction.timeRange.duration) * 1_000_000).rounded())

    let image = ClipTransitionEffects.compose(
      type: instruction.type, direction: instruction.direction,
      outgoing: outgoing, incoming: incoming, size: size,
      progress: applyEasing(linear, curve: instruction.curve),
      linearProgress: linear, durationUs: durationUs)
    context.render(image, to: target)
    request.finish(withComposedVideoFrame: target)
  }

  /// `frame`, upright, moved by `motion` as it applies at `time` into the
  /// blend.
  private func moved(_ frame: CIImage, by motion: TransitionSideMotion?, at time: CMTime?)
    -> CIImage
  {
    guard let motion, let time, let placement = motion.motion(at: time),
      !placement.isIdentity
    else { return frame }
    return applyFrameMotion(placement, to: frame)
  }

  /// The frame of track `trackID` at the request's time, upright, or nil when
  /// the track has none there.
  private func source(
    _ request: AVAsynchronousVideoCompositionRequest, _ trackID: CMPersistentTrackID,
    _ transform: CGAffineTransform, size: CGSize
  ) -> CIImage? {
    request.sourceFrame(byTrackID: trackID).map {
      upright(CIImage(cvPixelBuffer: $0), transform, size: size)
    }
  }

  /// `image` turned upright by its track's `transform` and, should its size
  /// still differ from the frame's, stretched to fill it.
  private func upright(_ image: CIImage, _ transform: CGAffineTransform, size: CGSize) -> CIImage {
    var result = transform.isIdentity ? image : applyingAVFoundationTransform(transform, to: image)
    let extent = result.extent
    if extent.origin != .zero || extent.size != size, extent.width > 0, extent.height > 0 {
      result = result.transformed(
        by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
          .concatenating(
            CGAffineTransform(
              scaleX: size.width / extent.width, y: size.height / extent.height)))
    }
    return result.cropped(to: CGRect(origin: .zero, size: size))
  }
}
