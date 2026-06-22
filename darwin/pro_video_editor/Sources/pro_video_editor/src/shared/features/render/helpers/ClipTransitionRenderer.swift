import AVFoundation
import CoreGraphics
import Foundation

/// Pre-renders an **overlap** clip transition (dissolve / slide / push / wipe)
/// into a single short clip that the main render pipeline consumes as an
/// ordinary forward clip.
///
/// It builds a tiny two-track `AVMutableComposition` (outgoing tail on track A,
/// incoming head on track B, fully overlapping for the transition duration) and
/// drives the transition with native `AVMutableVideoCompositionLayerInstruction`
/// ramps:
/// - **dissolve** → opacity ramp on the top layer,
/// - **slide** → transform ramp on the incoming layer,
/// - **push** → transform ramps on both layers,
/// - **wipe** → crop-rectangle ramp on the incoming layer.
///
/// The ramps are applied piecewise so the requested easing [curve] is honored.
/// Audio is cross-faded via an `AVMutableAudioMix`. The result is exported with
/// `AVAssetExportSession`.
///
/// Mirrors the Android `ClipTransitionRenderer` pre-render strategy and keeps
/// the main composition pipeline single-track. Returns `nil` on failure so the
/// caller can fall back to a hard cut.
internal enum ClipTransitionRenderer {

  /// Number of piecewise steps used to approximate an easing curve in the
  /// linear AVFoundation ramps.
  private static let easingSteps = 30

  struct RenderResult {
    let outputURL: URL
    let durationUs: Int64
  }

  static func render(
    outgoingPath: String,
    outTailStartUs: Int64,
    outTailEndUs: Int64,
    incomingPath: String,
    inHeadStartUs: Int64,
    inHeadEndUs: Int64,
    type: String,
    direction: String,
    curve: String,
    includeAudio: Bool,
    outputFormat: String
  ) async -> RenderResult? {
    do {
      let outAsset = AVURLAsset(url: URL(fileURLWithPath: outgoingPath))
      let inAsset = AVURLAsset(url: URL(fileURLWithPath: incomingPath))

      let outVideo = try await MediaInfoExtractor.loadVideoTrack(from: outAsset)
      let inVideo = try await MediaInfoExtractor.loadVideoTrack(from: inAsset)

      let dUs = max(outTailEndUs - outTailStartUs, inHeadEndUs - inHeadStartUs)
      guard dUs > 0 else { return nil }
      let d = CMTime(value: dUs, timescale: 1_000_000)

      let composition = AVMutableComposition()
      guard
        let trackA = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
        let trackB = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { return nil }

      let outStart = CMTime(value: outTailStartUs, timescale: 1_000_000)
      let inStart = CMTime(value: inHeadStartUs, timescale: 1_000_000)
      try trackA.insertTimeRange(
        CMTimeRange(start: outStart, duration: d), of: outVideo, at: .zero)
      try trackB.insertTimeRange(
        CMTimeRange(start: inStart, duration: d), of: inVideo, at: .zero)

      let transformA = try await loadPreferredTransform(outVideo)
      let transformB = try await loadPreferredTransform(inVideo)
      let naturalA = try await loadNaturalSize(outVideo)
      let naturalB = try await loadNaturalSize(inVideo)

      let displayA = naturalA.applying(transformA)
      let renderSize = CGSize(width: abs(displayA.width), height: abs(displayA.height))

      // Optional cross-faded audio.
      var audioMix: AVMutableAudioMix?
      if includeAudio {
        audioMix = try await buildAudioMix(
          composition: composition,
          outAsset: outAsset, outStart: outStart,
          inAsset: inAsset, inStart: inStart,
          duration: d, curve: curve)
      }

      // Build the layer instructions with eased ramps.
      let layerA = AVMutableVideoCompositionLayerInstruction(assetTrack: trackA)
      let layerB = AVMutableVideoCompositionLayerInstruction(assetTrack: trackB)
      layerA.setTransform(transformA, at: .zero)
      layerB.setTransform(transformB, at: .zero)

      applyRamps(
        type: type, direction: direction, curve: curve,
        layerA: layerA, layerB: layerB,
        transformA: transformA, transformB: transformB,
        renderSize: renderSize, naturalB: naturalB, duration: d)

      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = CMTimeRange(start: .zero, duration: d)
      // First layer instruction is composited on top.
      instruction.layerInstructions = orderedLayers(
        type: type, layerA: layerA, layerB: layerB)

      let videoComposition = AVMutableVideoComposition()
      videoComposition.renderSize = renderSize
      let fps = try await loadFrameRate(outVideo)
      videoComposition.frameDuration = CMTime(
        value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))
      videoComposition.instructions = [instruction]

      // Export.
      let outputURL = temporaryURL(for: outputFormat)
      guard
        let export = AVAssetExportSession(
          asset: composition, presetName: AVAssetExportPresetHighestQuality)
      else { return nil }
      export.outputURL = outputURL
      export.outputFileType = (outputFormat.lowercased() == "mov") ? .mov : .mp4
      export.videoComposition = videoComposition
      if let audioMix = audioMix {
        export.audioMix = audioMix
      }
      export.shouldOptimizeForNetworkUse = false

      try await runExport(export)

      PluginLog.print(
        "🎞️ Transition pre-render done (\(type)/\(direction)): "
          + "\(outputURL.lastPathComponent), \(dUs / 1000)ms")
      return RenderResult(outputURL: outputURL, durationUs: dUs)
    } catch {
      PluginLog.print("⚠️ Transition pre-render failed (\(type)): \(error)")
      return nil
    }
  }

  // MARK: - Ramps

  private static func orderedLayers(
    type: String,
    layerA: AVMutableVideoCompositionLayerInstruction,
    layerB: AVMutableVideoCompositionLayerInstruction
  ) -> [AVMutableVideoCompositionLayerInstruction] {
    switch type {
    case "dissolve":
      // Outgoing (A) on top, fading out to reveal incoming (B) behind.
      return [layerA, layerB]
    default:
      // Incoming (B) on top (slides/wipes/pushes in over A).
      return [layerB, layerA]
    }
  }

  private static func applyRamps(
    type: String, direction: String, curve: String,
    layerA: AVMutableVideoCompositionLayerInstruction,
    layerB: AVMutableVideoCompositionLayerInstruction,
    transformA: CGAffineTransform, transformB: CGAffineTransform,
    renderSize: CGSize, naturalB: CGSize, duration d: CMTime
  ) {
    let steps = easingSteps
    for k in 0..<steps {
      let f0 = Double(k) / Double(steps)
      let f1 = Double(k + 1) / Double(steps)
      let p0 = applyEasing(f0, curve: curve)
      let p1 = applyEasing(f1, curve: curve)
      let subRange = CMTimeRange(
        start: CMTimeMultiplyByFloat64(d, multiplier: f0),
        duration: CMTimeMultiplyByFloat64(d, multiplier: f1 - f0))

      switch type {
      case "dissolve":
        layerA.setOpacityRamp(
          fromStartOpacity: Float(1.0 - p0),
          toEndOpacity: Float(1.0 - p1),
          timeRange: subRange)
      case "slide":
        layerB.setTransformRamp(
          fromStart: incomingTransform(transformB, direction, renderSize, p0),
          toEnd: incomingTransform(transformB, direction, renderSize, p1),
          timeRange: subRange)
      case "push":
        layerB.setTransformRamp(
          fromStart: incomingTransform(transformB, direction, renderSize, p0),
          toEnd: incomingTransform(transformB, direction, renderSize, p1),
          timeRange: subRange)
        layerA.setTransformRamp(
          fromStart: outgoingTransform(transformA, direction, renderSize, p0),
          toEnd: outgoingTransform(transformA, direction, renderSize, p1),
          timeRange: subRange)
      case "wipe":
        layerB.setCropRectangleRamp(
          fromStartCropRectangle: wipeCrop(naturalB, direction, p0),
          toEndCropRectangle: wipeCrop(naturalB, direction, p1),
          timeRange: subRange)
      default:
        break
      }
    }
  }

  /// Translation (in render space) applied to the incoming clip at progress [p].
  private static func incomingTransform(
    _ base: CGAffineTransform, _ direction: String, _ size: CGSize, _ p: Double
  ) -> CGAffineTransform {
    let inv = CGFloat(1.0 - p)
    var tx: CGFloat = 0
    var ty: CGFloat = 0
    switch direction {
    case "left": tx = size.width * inv  // enters from the right
    case "right": tx = -size.width * inv  // enters from the left
    case "up": ty = size.height * inv  // enters from the bottom
    case "down": ty = -size.height * inv  // enters from the top
    default: tx = size.width * inv
    }
    return base.concatenating(CGAffineTransform(translationX: tx, y: ty))
  }

  /// Translation (in render space) applied to the outgoing clip at progress [p].
  private static func outgoingTransform(
    _ base: CGAffineTransform, _ direction: String, _ size: CGSize, _ p: Double
  ) -> CGAffineTransform {
    let prog = CGFloat(p)
    var tx: CGFloat = 0
    var ty: CGFloat = 0
    switch direction {
    case "left": tx = -size.width * prog  // exits to the left
    case "right": tx = size.width * prog  // exits to the right
    case "up": ty = -size.height * prog  // exits to the top
    case "down": ty = size.height * prog  // exits to the bottom
    default: tx = -size.width * prog
    }
    return base.concatenating(CGAffineTransform(translationX: tx, y: ty))
  }

  /// Crop rectangle (in source coordinates) revealing the incoming clip at [p].
  private static func wipeCrop(_ size: CGSize, _ direction: String, _ p: Double)
    -> CGRect
  {
    let w = size.width
    let h = size.height
    let prog = CGFloat(p)
    switch direction {
    case "right": return CGRect(x: 0, y: 0, width: w * prog, height: h)
    case "left": return CGRect(x: w * (1 - prog), y: 0, width: w * prog, height: h)
    case "down": return CGRect(x: 0, y: 0, width: w, height: h * prog)
    case "up": return CGRect(x: 0, y: h * (1 - prog), width: w, height: h * prog)
    default: return CGRect(x: 0, y: 0, width: w * prog, height: h)
    }
  }

  // MARK: - Audio

  private static func buildAudioMix(
    composition: AVMutableComposition,
    outAsset: AVURLAsset, outStart: CMTime,
    inAsset: AVURLAsset, inStart: CMTime,
    duration d: CMTime, curve: String
  ) async throws -> AVMutableAudioMix? {
    guard
      let outAudio = try? await MediaInfoExtractor.loadAudioTrack(from: outAsset),
      let inAudio = try? await MediaInfoExtractor.loadAudioTrack(from: inAsset),
      let trackA = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
      let trackB = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else { return nil }

    try trackA.insertTimeRange(CMTimeRange(start: outStart, duration: d), of: outAudio, at: .zero)
    try trackB.insertTimeRange(CMTimeRange(start: inStart, duration: d), of: inAudio, at: .zero)

    let paramsA = AVMutableAudioMixInputParameters(track: trackA)
    let paramsB = AVMutableAudioMixInputParameters(track: trackB)
    let fullRange = CMTimeRange(start: .zero, duration: d)
    // Linear cross-fade is a good approximation; the visual curve drives feel.
    paramsA.setVolumeRamp(fromStartVolume: 1.0, toEndVolume: 0.0, timeRange: fullRange)
    paramsB.setVolumeRamp(fromStartVolume: 0.0, toEndVolume: 1.0, timeRange: fullRange)

    let mix = AVMutableAudioMix()
    mix.inputParameters = [paramsA, paramsB]
    return mix
  }

  // MARK: - Export

  private static func runExport(_ export: AVAssetExportSession) async throws {
    if #available(iOS 18.0, macOS 15.0, *) {
      try await export.export(to: export.outputURL!, as: export.outputFileType!)
    } else {
      try await withCheckedThrowingContinuation {
        (cont: CheckedContinuation<Void, Error>) in
        export.exportAsynchronously {
          if export.status == .completed {
            cont.resume()
          } else {
            cont.resume(
              throwing: export.error
                ?? NSError(
                  domain: "ClipTransitionRenderer", code: 1,
                  userInfo: [
                    NSLocalizedDescriptionKey:
                      "Transition export failed (status \(export.status.rawValue))"
                  ]))
          }
        }
      }
    }
  }

  // MARK: - Track property loading

  private static func loadPreferredTransform(_ track: AVAssetTrack) async throws
    -> CGAffineTransform
  {
    if #available(iOS 15.0, macOS 13.0, *) {
      return try await track.load(.preferredTransform)
    }
    return track.preferredTransform
  }

  private static func loadNaturalSize(_ track: AVAssetTrack) async throws -> CGSize {
    if #available(iOS 15.0, macOS 13.0, *) {
      return try await track.load(.naturalSize)
    }
    return track.naturalSize
  }

  private static func loadFrameRate(_ track: AVAssetTrack) async throws -> Float {
    let rate: Float
    if #available(iOS 15.0, macOS 13.0, *) {
      rate = (try? await track.load(.nominalFrameRate)) ?? 30
    } else {
      rate = track.nominalFrameRate
    }
    return rate > 0 ? rate : 30
  }

  private static func temporaryURL(for format: String) -> URL {
    let ext = format.lowercased() == "mov" ? "mov" : "mp4"
    let name = "transition_\(Int(Date().timeIntervalSince1970 * 1000))_\(UInt32.random(in: 0...UInt32.max)).\(ext)"
    return FileManager.default.temporaryDirectory.appendingPathComponent(name)
  }
}
