import AVFoundation
import CoreGraphics
import Foundation

/// Pre-renders an **overlap** clip transition into a single short clip that
/// the main render pipeline consumes as an ordinary forward clip.
///
/// It builds a tiny two-track `AVMutableComposition` (outgoing tail on track A,
/// incoming head on track B, fully overlapping for the transition duration) and
/// drives the transition with native `AVMutableVideoCompositionLayerInstruction`
/// ramps:
/// - **dissolve** → opacity ramp on the top layer,
/// - **slide** → transform ramp on the incoming layer,
/// - **push** → transform ramps on both layers,
/// - **wipe** → crop-rectangle ramp on the incoming layer,
/// - every type ``ClipTransitionEffects`` handles → ``ClipTransitionCompositor``,
///   which draws each frame from both source frames with Core Image.
///
/// The ramps are applied piecewise so the requested easing [curve] is honored.
/// Audio is cross-faded along the same curve via an `AVMutableAudioMix`. The
/// result is exported with `AVAssetExportSession`.
///
/// Mirrors the Android `ClipTransitionRenderer` pre-render strategy and keeps
/// the main composition pipeline single-track. Returns `nil` on failure so the
/// caller can fall back to a hard cut — except for a stalled encode
/// (``SetupStageExport/isStall(_:)``), which is thrown: it says the encoder is
/// starved or wedged, not that the blend cannot be rendered, and a hard cut
/// cached in its place would outlive the stall.
internal enum ClipTransitionRenderer {

  /// Lower bound on the piecewise steps used to approximate an easing curve in
  /// the linear AVFoundation ramps.
  private static let minEasingSteps = 30

  /// Upper bound on easing steps, to cap the instruction count on long/high-fps
  /// transitions.
  private static let maxEasingSteps = 240

  /// Piecewise easing-step count for a transition of `durationUs` sampled at
  /// `fps`: roughly one linear segment per output frame, clamped to
  /// `[minEasingSteps, maxEasingSteps]`. With one segment per frame the linear
  /// ramps track the easing curve closely, so `slide`/`push` no longer show
  /// velocity kinks between the old fixed 30 segments.
  private static func easingStepCount(durationUs: Int64, fps: Int) -> Int {
    let frames = Int((Double(durationUs) / 1_000_000.0 * Double(fps)).rounded())
    return min(maxEasingSteps, max(minEasingSteps, frames))
  }

  struct RenderResult {
    let outputURL: URL
    let durationUs: Int64
  }

  /// One clip's own audio settings, applied to its side of the crossfade the
  /// way its own audio is, so the blend sounds like the clips around it.
  struct SideAudio {
    var volume: Float?
    var equalizer: AudioEqualizer?

    init(volume: Float? = nil, equalizer: AudioEqualizer? = nil) {
      self.volume = volume
      self.equalizer = equalizer
    }
  }

  static func render(
    outgoingPath: String,
    outTailStartUs: Int64,
    outTailEndUs: Int64,
    incomingPath: String,
    inHeadStartUs: Int64,
    inHeadEndUs: Int64,
    outputDurationUs: Int64,
    type: String,
    direction: String,
    curve: String,
    includeAudio: Bool,
    outputFormat: String,
    outgoingFrameRate: Float? = nil,
    incomingFrameRate: Float? = nil,
    outgoingAudio: SideAudio = SideAudio(),
    incomingAudio: SideAudio = SideAudio()
  ) async throws -> RenderResult? {
    // Only a *successful* blend reaches the caller, so only a successful blend
    // can be cleaned up by it. An export that fails, stalls or is cancelled
    // mid-write has to remove its own partial file here, or it stays in the
    // temporary directory for good.
    var partialOutput: URL?
    do {
      let outAsset = AVURLAsset(url: URL(fileURLWithPath: outgoingPath))
      let inAsset = AVURLAsset(url: URL(fileURLWithPath: incomingPath))

      let outVideo = try await MediaInfoExtractor.loadVideoTrack(from: outAsset)
      let inVideo = try await MediaInfoExtractor.loadVideoTrack(from: inAsset)

      // Source spans consumed from each side (already speed-scaled by the
      // caller) and the shared OUTPUT (post-speed) duration of the blend.
      let outTailDurUs = outTailEndUs - outTailStartUs
      let inHeadDurUs = inHeadEndUs - inHeadStartUs
      let dUs = outputDurationUs
      guard dUs > 0, outTailDurUs > 0, inHeadDurUs > 0 else { return nil }
      let d = CMTime(value: dUs, timescale: 1_000_000)
      let outTailDur = CMTime(value: outTailDurUs, timescale: 1_000_000)
      let inHeadDur = CMTime(value: inHeadDurUs, timescale: 1_000_000)

      let composition = AVMutableComposition()
      guard
        let trackA = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
        let trackB = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { return nil }

      let outStart = CMTime(value: outTailStartUs, timescale: 1_000_000)
      let inStart = CMTime(value: inHeadStartUs, timescale: 1_000_000)
      // Only the part of each span its video track holds. A container can
      // outlast its video (demo_world.mp4 by ~0.5 s), and `insertTimeRange`
      // silently stops at the track's end: the blend then had no outgoing
      // frames for its last part, so the compositor failed the export (a hard
      // cut) and the ramps drew nothing for the outgoing clip. Spreading what
      // the track holds over the blend matches Android, which spreads the
      // frames it decodes.
      let outVideoRange = CMTimeRangeGetIntersection(
        CMTimeRange(start: outStart, duration: outTailDur),
        otherRange: await TrackEndTrimmer.timeRange(of: outVideo))
      let inVideoRange = CMTimeRangeGetIntersection(
        CMTimeRange(start: inStart, duration: inHeadDur),
        otherRange: await TrackEndTrimmer.timeRange(of: inVideo))
      guard outVideoRange.duration > .zero, inVideoRange.duration > .zero else { return nil }
      try trackA.insertTimeRange(outVideoRange, of: outVideo, at: .zero)
      try trackB.insertTimeRange(inVideoRange, of: inVideo, at: .zero)

      // Apply each side's playback speed by scaling its inserted span to the
      // shared output duration, so the footage inside the blend plays at the
      // requested speed (the ramps below all run over the output duration `d`).
      if outVideoRange.duration != d {
        trackA.scaleTimeRange(
          CMTimeRange(start: .zero, duration: outVideoRange.duration), toDuration: d)
      }
      if inVideoRange.duration != d {
        trackB.scaleTimeRange(
          CMTimeRange(start: .zero, duration: inVideoRange.duration), toDuration: d)
      }

      let transformA = try await loadPreferredTransform(outVideo)
      let transformB = try await loadPreferredTransform(inVideo)
      let naturalA = try await loadNaturalSize(outVideo)
      let naturalB = try await loadNaturalSize(inVideo)

      let displayA = naturalA.applying(transformA)
      let renderSize = CGSize(width: abs(displayA.width), height: abs(displayA.height))

      // Author the transition at the same cadence the main composition uses
      // (max(30, source fps); see LayeredCompositionBuilder). Deriving it from
      // only the outgoing clip's fps left the pre-rendered transition below the
      // composition's frame rate (e.g. 25 vs 30 fps), so it was re-timed on
      // insertion and stuttered at the two seams.
      // A side cut down by the HDR pre-transcode passes the cadence measured
      // from its frames: that shorter file's `nominalFrameRate` misreads it
      // (see `VideoClip.frameRateOverride`).
      let outFps: Float
      if let outgoingFrameRate {
        outFps = outgoingFrameRate
      } else {
        outFps = try await loadFrameRate(outVideo)
      }
      let inFps: Float
      if let incomingFrameRate {
        inFps = incomingFrameRate
      } else {
        inFps = try await loadFrameRate(inVideo)
      }
      let targetFps = max(30, Int(max(outFps, inFps).rounded()))
      let steps = easingStepCount(durationUs: dUs, fps: targetFps)

      // Optional cross-faded audio.
      var audioMix: AVMutableAudioMix?
      if includeAudio {
        audioMix = try await buildAudioMix(
          composition: composition,
          outAsset: outAsset, outStart: outStart, outDuration: outTailDur,
          inAsset: inAsset, inStart: inStart, inDuration: inHeadDur,
          duration: d, curve: curve, steps: steps,
          outgoingAudio: outgoingAudio, incomingAudio: incomingAudio)
      }

      let videoComposition = AVMutableVideoComposition()
      videoComposition.renderSize = renderSize
      videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))

      if ClipTransitionEffects.handles(type) {
        // Zooms, turns, blurs and flashes need both frames at once, which
        // layer instructions cannot give; a compositor draws each frame.
        videoComposition.customVideoCompositorClass = ClipTransitionCompositor.self
        videoComposition.instructions = [
          ClipTransitionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: d),
            outgoingTrackID: trackA.trackID, incomingTrackID: trackB.trackID,
            outgoingTransform: transformA, incomingTransform: transformB,
            type: type, direction: direction, curve: curve,
            frameDuration: videoComposition.frameDuration)
        ]
      } else {
        // Build the layer instructions with eased ramps.
        let layerA = AVMutableVideoCompositionLayerInstruction(assetTrack: trackA)
        let layerB = AVMutableVideoCompositionLayerInstruction(assetTrack: trackB)
        layerA.setTransform(transformA, at: .zero)
        layerB.setTransform(transformB, at: .zero)

        applyRamps(
          type: type, direction: direction, curve: curve,
          layerA: layerA, layerB: layerB,
          transformA: transformA, transformB: transformB,
          renderSize: renderSize, naturalB: naturalB, duration: d, steps: steps)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: d)
        // First layer instruction is composited on top.
        instruction.layerInstructions = orderedLayers(
          type: type, layerA: layerA, layerB: layerB)
        videoComposition.instructions = [instruction]
      }

      // Export.
      let outputURL = temporaryURL(for: outputFormat)
      partialOutput = outputURL
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

      try await runExport(
        export,
        diagnostics: TransitionExportDiagnostics(
          type: type, direction: direction, durationUs: dUs))
      // Handed to the caller from here on, which tracks it for cleanup.
      partialOutput = nil

      PluginLog.print(
        "🎞️ Transition pre-render done (\(type)/\(direction)): "
          + "\(outputURL.lastPathComponent), \(dUs / 1000)ms")
      return RenderResult(outputURL: outputURL, durationUs: dUs)
    } catch {
      PluginLog.print("⚠️ Transition pre-render failed (\(type)): \(error)")
      if let partialOutput {
        try? FileManager.default.removeItem(at: partialOutput)
      }
      if SetupStageExport.isStall(error) { throw error }
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
    renderSize: CGSize, naturalB: CGSize, duration d: CMTime, steps: Int
  ) {
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

  /// Adds each side's audio to [composition] and cross-fades the two along
  /// [curve] over [d], in [steps] ramps; see ``crossfadeRamps``.
  ///
  /// Each side starts or ends at its own clip's volume, through its own
  /// equalizer, limited like the clip where either would clip. A muted side
  /// is left out, and the other fades in or out against silence.
  static func buildAudioMix(
    composition: AVMutableComposition,
    outAsset: AVURLAsset, outStart: CMTime, outDuration: CMTime,
    inAsset: AVURLAsset, inStart: CMTime, inDuration: CMTime,
    duration d: CMTime, curve: String, steps: Int,
    outgoingAudio: SideAudio, incomingAudio: SideAudio
  ) async throws -> AVMutableAudioMix? {
    let sides = [
      (
        asset: outAsset, start: outStart, duration: outDuration, audio: outgoingAudio,
        fadesIn: false
      ),
      (
        asset: inAsset, start: inStart, duration: inDuration, audio: incomingAudio,
        fadesIn: true
      ),
    ].filter { ($0.audio.volume ?? 1) > 0 }
    guard !sides.isEmpty else { return nil }
    // Every side's source first: a track added for one side would otherwise
    // play unfaded in the blend when the other has no audio to load.
    var sources: [AVAssetTrack] = []
    for side in sides {
      guard let source = try? await MediaInfoExtractor.loadAudioTrack(from: side.asset)
      else { return nil }
      sources.append(source)
    }

    var parameters: [AVMutableAudioMixInputParameters] = []
    for (side, sourceAudio) in zip(sides, sources) {
      guard
        let track = composition.addMutableTrack(
          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { return nil }
      try track.insertTimeRange(
        CMTimeRange(start: side.start, duration: side.duration), of: sourceAudio, at: .zero)
      // Speed-scale each side's audio to the shared output duration so it
      // stays aligned with the speed-adjusted video and the blend length
      // matches.
      if side.duration != d {
        track.scaleTimeRange(CMTimeRange(start: .zero, duration: side.duration), toDuration: d)
      }

      let volume = side.audio.volume ?? 1
      let params = AVMutableAudioMixInputParameters(track: track)
      for ramp in crossfadeRamps(
        volume: volume, fadesIn: side.fadesIn, curve: curve, duration: d, steps: steps)
      {
        params.setVolumeRamp(
          fromStartVolume: ramp.from, toEndVolume: ramp.to, timeRange: ramp.range)
      }
      params.audioTapProcessor = AudioMixTap.make(
        volumes: VolumeSchedule(constant: volume),
        equalizers: EqualizerSchedule(constant: side.audio.equalizer))
      parameters.append(params)
    }

    let mix = AVMutableAudioMix()
    mix.inputParameters = parameters
    return mix
  }

  /// The volume ramps that fade one side of a blend of duration [d] along
  /// [curve]: the incoming side plays at `volume × p` and the outgoing one at
  /// `volume × (1 − p)`, p being the eased progress, as on Android. A mix
  /// only ramps linearly, so the curve is followed piecewise, one ramp per
  /// easing step like the video in ``applyRamps``, each starting exactly where
  /// the one before it ends.
  ///
  /// p is held within 0...1. An elastic curve springs past its ends, and
  /// Android follows it there, playing one clip louder than its own volume
  /// and the other phase-inverted. A mix has no negative volume, and the tap
  /// limits each side for its own volume only, so here each side stops at its
  /// own volume or at silence through the overshoot instead.
  static func crossfadeRamps(
    volume: Float, fadesIn: Bool, curve: String, duration d: CMTime, steps: Int
  ) -> [(from: Float, to: Float, range: CMTimeRange)] {
    func time(_ k: Int) -> CMTime {
      k == steps ? d : CMTimeMultiplyByFloat64(d, multiplier: Double(k) / Double(steps))
    }
    func gain(_ k: Int) -> Float {
      let p = Float(min(1, max(0, applyEasing(Double(k) / Double(steps), curve: curve))))
      return volume * (fadesIn ? p : 1 - p)
    }
    return (0..<steps).map { k in
      (gain(k), gain(k + 1), CMTimeRange(start: time(k), end: time(k + 1)))
    }
  }

  // MARK: - Export

  /// A pre-render is not progress-reported to the caller (the blends are
  /// short), but it runs through the shared driver — the continuation this
  /// used to wait on was immune to cancellation, so on pre-iOS 18 a transition
  /// kept encoding long after its render job had been cancelled — and, being a
  /// hardware encode of its own, inside the gate slot and under the stall
  /// watchdog like the main encode (#201).
  private static func runExport(
    _ export: AVAssetExportSession, diagnostics: TransitionExportDiagnostics
  ) async throws {
    try await SetupStageExport.run(
      export, diagnostics: diagnostics, label: "ClipTransition",
      failureDomain: "ClipTransitionRenderer")
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

/// Diagnostic context for an overlap-transition pre-render, mirroring
/// ``RenderExportDiagnostics`` so a stall surfaces the same shape of message
/// as one on the main encode.
struct TransitionExportDiagnostics: ExportDiagnostics {
  let type: String
  let direction: String
  let durationUs: Int64

  /// e.g. `[progress=0.00 type=dissolve direction=left duration=500ms]`
  func context(progress: Double) -> String {
    String(
      format: "[progress=%.2f type=%@ direction=%@ duration=%ldms]",
      progress, type, direction, Int(durationUs / 1000))
  }

  func timeoutMessage(seconds: Int, progress: Double) -> String {
    "Transition pre-render timed out after \(seconds)s \(context(progress: progress))"
  }

  func stallMessage(seconds: Int, progress: Double) -> String {
    "Transition pre-render stalled after \(seconds)s with no progress "
      + context(progress: progress)
  }
}
