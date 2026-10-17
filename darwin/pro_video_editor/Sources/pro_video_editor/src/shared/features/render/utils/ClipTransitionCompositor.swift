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

  var requiredSourceTrackIDs: [NSValue]? {
    [NSNumber(value: outgoingTrackID), NSNumber(value: incomingTrackID)]
  }

  init(
    timeRange: CMTimeRange,
    outgoingTrackID: CMPersistentTrackID, incomingTrackID: CMPersistentTrackID,
    outgoingTransform: CGAffineTransform, incomingTransform: CGAffineTransform,
    type: String, direction: String, curve: String, frameDuration: CMTime
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
    guard let instruction = request.videoCompositionInstruction as? ClipTransitionInstruction,
      let outgoingBuffer = request.sourceFrame(byTrackID: instruction.outgoingTrackID),
      let incomingBuffer = request.sourceFrame(byTrackID: instruction.incomingTrackID),
      let target = request.renderContext.newPixelBuffer()
    else {
      request.finish(
        with: NSError(
          domain: "ClipTransitionCompositor", code: 0,
          userInfo: [
            NSLocalizedDescriptionKey: "A transition frame is missing a source or an output buffer"
          ]))
      return
    }

    let size = request.renderContext.size
    let outgoing = upright(
      CIImage(cvPixelBuffer: outgoingBuffer), instruction.outgoingTransform, size: size)
    let incoming = upright(
      CIImage(cvPixelBuffer: incomingBuffer), instruction.incomingTransform, size: size)
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
