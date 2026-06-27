import AVFoundation
import CoreGraphics
import Foundation

/// Builds a multi-layer `AVMutableComposition` from a ``CompositionConfig``.
///
/// Each layer becomes its own video (and audio) track. Clips on a layer are
/// placed back-to-back, or at their explicit `timelineStart`. The timeline is
/// then segmented at every clip boundary, and one layered instruction is
/// produced per window listing the layers visible in that window in z-order
/// (bottom-to-top). The custom ``VideoCompositor`` composites those layers.
///
/// The return shape matches ``CompositionBuilder`` so the layered path can reuse
/// the rest of the render pipeline (effects, export) unchanged.
internal class LayeredCompositionBuilder {
  private let config: CompositionConfig
  private var enableAudio: Bool = true
  private var audioTracks: [AudioTrackConfig] = []

  init(composition: CompositionConfig) {
    self.config = composition
  }

  func setEnableAudio(_ enabled: Bool) -> LayeredCompositionBuilder {
    self.enableAudio = enabled
    return self
  }

  func setAudioTracks(_ tracks: [AudioTrackConfig]) -> LayeredCompositionBuilder {
    self.audioTracks = tracks
    return self
  }

  /// A clip after it has been inserted onto its layer's track, with the data
  /// needed to build instructions and the audio mix.
  private struct PlacedClip {
    let layerIndex: Int
    let trackID: CMPersistentTrackID
    let startUs: Int64  // timeline
    let endUs: Int64  // timeline
    let opacity: Float
    let transformConfig: SegmentTransformConfig?
    let preferredTransform: CGAffineTransform
    let displaySize: CGSize
  }

  private struct AudioWindow {
    let track: AVMutableCompositionTrack
    let volume: Float
    let range: CMTimeRange
  }

  func build() async throws -> (
    AVMutableComposition, VideoCompositionData, CGSize, AVAudioMix?, CMPersistentTrackID, [URL],
    [FadeWindow]
  ) {
    guard !config.layers.isEmpty else {
      throw NSError(
        domain: "LayeredCompositionBuilder", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Composition must contain at least one layer"])
    }

    let composition = AVMutableComposition()
    var placed: [PlacedClip] = []
    var audioWindows: [AudioWindow] = []
    var frameRate: Float = 30
    var firstDisplaySize: CGSize?
    var firstVideoTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    for (layerIndex, layer) in config.layers.enumerated() {
      guard
        let videoTrack = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { continue }
      if firstVideoTrackID == kCMPersistentTrackID_Invalid {
        firstVideoTrackID = videoTrack.trackID
      }
      var audioTrack: AVMutableCompositionTrack?
      var cursorUs: Int64 = 0

      for clip in layer.clips {
        let asset = AVURLAsset(url: URL(fileURLWithPath: clip.inputPath))
        guard let assetVideoTrack = await firstTrack(asset, .video) else { continue }

        let assetDurationUs = await durationUs(of: asset)
        let srcStartUs = max(0, clip.startUs ?? 0)
        let srcEndUs = clip.endUs ?? assetDurationUs
        let srcDurUs = srcEndUs - srcStartUs
        guard srcDurUs > 0 else { continue }

        let srcRange = CMTimeRange(
          start: CMTime(value: srcStartUs, timescale: 1_000_000),
          duration: CMTime(value: srcDurUs, timescale: 1_000_000))

        // Place at the explicit timelineStart, or back-to-back. Clamp to the
        // current cursor so clips on a layer never overlap.
        let requestedStartUs = clip.timelineStartUs ?? cursorUs
        let timelineStartUs = max(cursorUs, requestedStartUs)
        let at = CMTime(value: timelineStartUs, timescale: 1_000_000)

        // Pad a leading gap on this track so frames land at the right time.
        if timelineStartUs > cursorUs {
          videoTrack.insertEmptyTimeRange(
            CMTimeRange(
              start: CMTime(value: cursorUs, timescale: 1_000_000),
              duration: CMTime(value: timelineStartUs - cursorUs, timescale: 1_000_000)))
        }

        do {
          try videoTrack.insertTimeRange(srcRange, of: assetVideoTrack, at: at)
        } catch {
          PluginLog.print("⚠️ Layered: failed to insert video clip: \(error)")
          continue
        }

        // Audio (per-clip volume applied via the audio mix below).
        let volume = clip.volume ?? 1.0
        if enableAudio, volume > 0, let assetAudioTrack = await firstTrack(asset, .audio) {
          if audioTrack == nil {
            audioTrack = composition.addMutableTrack(
              withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
          }
          if let audioTrack = audioTrack {
            if timelineStartUs > cursorUs {
              audioTrack.insertEmptyTimeRange(
                CMTimeRange(
                  start: CMTime(value: cursorUs, timescale: 1_000_000),
                  duration: CMTime(value: timelineStartUs - cursorUs, timescale: 1_000_000)))
            }
            try? audioTrack.insertTimeRange(srcRange, of: assetAudioTrack, at: at)
            audioWindows.append(
              AudioWindow(
                track: audioTrack, volume: volume,
                range: CMTimeRange(start: at, duration: srcRange.duration)))
          }
        }

        let timelineEndUs = timelineStartUs + srcDurUs
        cursorUs = timelineEndUs

        let pt = await preferredTransform(of: assetVideoTrack)
        let natural = await naturalSize(of: assetVideoTrack)
        let display = natural.applying(pt)
        let displaySize = CGSize(width: abs(display.width), height: abs(display.height))
        if firstDisplaySize == nil { firstDisplaySize = displaySize }

        let fr = await nominalFrameRate(of: assetVideoTrack)
        if fr > frameRate { frameRate = fr }

        placed.append(
          PlacedClip(
            layerIndex: layerIndex,
            trackID: videoTrack.trackID,
            startUs: timelineStartUs,
            endUs: timelineEndUs,
            opacity: layer.opacity,
            transformConfig: clip.transform ?? layer.transform,
            preferredTransform: pt,
            displaySize: displaySize))
      }
    }

    guard !placed.isEmpty else {
      throw NSError(
        domain: "LayeredCompositionBuilder", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Composition produced no usable clips"])
    }

    // Resolve the canvas size: explicit, else the first clip's display size.
    let canvasSize: CGSize
    if let w = config.canvasWidth, let h = config.canvasHeight {
      canvasSize = CGSize(width: w, height: h)
    } else {
      canvasSize = firstDisplaySize ?? CGSize(width: 1920, height: 1080)
    }

    let instructions = buildInstructions(placed: placed, canvasSize: canvasSize)
    let frameDuration = CMTime(value: 1, timescale: Int32(max(30, frameRate)))
    let videoCompositionData = VideoCompositionData(
      instructions: instructions, frameDuration: frameDuration, renderSize: canvasSize)

    // Custom audio tracks, inserted as extra audio tracks and mixed in.
    var temporaryAudioURLs: [URL] = []
    var customAudioParams: [AVMutableAudioMixInputParameters] = []
    if !audioTracks.isEmpty {
      let totalDurUs = placed.map { $0.endUs }.max() ?? 0
      let targetDuration = CMTime(value: totalDurUs, timescale: 1_000_000)
      for trackConfig in audioTracks {
        let audioBuilder = AudioSequenceBuilder(
          audioPath: trackConfig.path, targetDuration: targetDuration
        ).setLoop(trackConfig.loop)
          .setAudioStartTime(trackConfig.audioStartUs)
          .setAudioEndTime(trackConfig.audioEndUs)
          .setCompositionStartTime(trackConfig.startUs == -1 ? nil : trackConfig.startUs)
          .setCompositionEndTime(trackConfig.endUs == -1 ? nil : trackConfig.endUs)
        if let result = try await audioBuilder.build(in: composition) {
          let params = AVMutableAudioMixInputParameters(track: result.track)
          params.setVolume(trackConfig.volume, at: .zero)
          customAudioParams.append(params)
          temporaryAudioURLs.append(result.temporaryURL)
        }
      }
    }

    let audioMix = makeAudioMix(audioWindows: audioWindows, extraParams: customAudioParams)

    PluginLog.print(
      "✅ Layered composition: \(config.layers.count) layers, \(placed.count) clips, "
        + "\(audioTracks.count) audio tracks, "
        + "canvas \(Int(canvasSize.width))x\(Int(canvasSize.height))")

    return (
      composition, videoCompositionData, canvasSize, audioMix, firstVideoTrackID,
      temporaryAudioURLs, []
    )
  }

  /// Segments the timeline at every clip boundary and produces one layered
  /// instruction per window.
  private func buildInstructions(placed: [PlacedClip], canvasSize: CGSize)
    -> [AVVideoCompositionInstructionProtocol]
  {
    // Collect and sort all distinct boundary times. Always include 0 so a
    // leading gap (no layer starts at 0) is still covered by a background
    // instruction; AVFoundation requires the timeline to be covered from 0.
    var boundarySet: Set<Int64> = [0]
    for clip in placed {
      boundarySet.insert(clip.startUs)
      boundarySet.insert(clip.endUs)
    }
    let boundaries = boundarySet.sorted()

    let background = backgroundCGColor()
    var instructions: [AVVideoCompositionInstructionProtocol] = []

    for i in 0..<max(0, boundaries.count - 1) {
      let windowStartUs = boundaries[i]
      let windowEndUs = boundaries[i + 1]
      guard windowEndUs > windowStartUs else { continue }

      // Clips active during this window, ordered bottom-to-top (layer index,
      // then insertion order for a stable z-order).
      let active = placed.filter { $0.startUs <= windowStartUs && $0.endUs > windowStartUs }
        .sorted { $0.layerIndex < $1.layerIndex }

      let placements: [LayerPlacement] = active.map { clip in
        LayerPlacement(
          trackID: clip.trackID,
          opacity: clip.opacity,
          targetRect: resolveRect(clip.transformConfig, displaySize: clip.displaySize),
          fit: clip.transformConfig?.fit ?? "fill",
          preferredTransform: clip.preferredTransform,
          displaySize: clip.displaySize)
      }

      let timeRange = CMTimeRange(
        start: CMTime(value: windowStartUs, timescale: 1_000_000),
        duration: CMTime(value: windowEndUs - windowStartUs, timescale: 1_000_000))

      instructions.append(
        CustomVideoCompositionInstruction(
          timeRange: timeRange, layerPlacements: placements, backgroundColor: background))
    }

    return instructions
  }

  /// Resolves the destination rectangle for a clip in canvas pixels (top-left
  /// origin). Returns `nil` to mean "fill the whole canvas".
  private func resolveRect(_ cfg: SegmentTransformConfig?, displaySize: CGSize) -> CGRect? {
    guard let cfg = cfg else { return nil }
    let x = CGFloat(cfg.offsetX ?? 0)
    let y = CGFloat(cfg.offsetY ?? 0)
    let w = CGFloat(cfg.width ?? Double(displaySize.width))
    let h = CGFloat(cfg.height ?? Double(displaySize.height))
    return CGRect(x: x, y: y, width: w, height: h)
  }

  private func makeAudioMix(
    audioWindows: [AudioWindow], extraParams: [AVMutableAudioMixInputParameters]
  ) -> AVAudioMix? {
    // One input-parameter set per layer track, with a volume ramp per clip
    // window, plus any custom audio-track parameters.
    var byTrack: [CMPersistentTrackID: [AudioWindow]] = [:]
    for w in audioWindows { byTrack[w.track.trackID, default: []].append(w) }

    var params: [AVMutableAudioMixInputParameters] = []
    for (_, windows) in byTrack {
      guard let track = windows.first?.track else { continue }
      let p = AVMutableAudioMixInputParameters(track: track)
      for w in windows {
        p.setVolumeRamp(fromStartVolume: w.volume, toEndVolume: w.volume, timeRange: w.range)
      }
      params.append(p)
    }
    params.append(contentsOf: extraParams)

    guard !params.isEmpty else { return nil }
    let mix = AVMutableAudioMix()
    mix.inputParameters = params
    return mix
  }

  private func backgroundCGColor() -> CGColor {
    let argb = config.backgroundColor
    let a = CGFloat((argb >> 24) & 0xFF) / 255.0
    let r = CGFloat((argb >> 16) & 0xFF) / 255.0
    let g = CGFloat((argb >> 8) & 0xFF) / 255.0
    let b = CGFloat(argb & 0xFF) / 255.0
    return CGColor(red: r, green: g, blue: b, alpha: a)
  }

  // MARK: - Async asset helpers

  private func firstTrack(_ asset: AVURLAsset, _ type: AVMediaType) async -> AVAssetTrack? {
    if #available(iOS 15.0, macOS 13.0, *) {
      return try? await asset.loadTracks(withMediaType: type).first
    } else {
      return asset.tracks(withMediaType: type).first
    }
  }

  private func durationUs(of asset: AVURLAsset) async -> Int64 {
    let dur: CMTime
    if #available(iOS 15.0, macOS 13.0, *) {
      dur = (try? await asset.load(.duration)) ?? .zero
    } else {
      dur = asset.duration
    }
    return Int64(CMTimeGetSeconds(dur) * 1_000_000)
  }

  private func preferredTransform(of track: AVAssetTrack) async -> CGAffineTransform {
    if #available(iOS 15.0, macOS 13.0, *) {
      return (try? await track.load(.preferredTransform)) ?? .identity
    } else {
      return track.preferredTransform
    }
  }

  private func naturalSize(of track: AVAssetTrack) async -> CGSize {
    if #available(iOS 15.0, macOS 13.0, *) {
      return (try? await track.load(.naturalSize)) ?? .zero
    } else {
      return track.naturalSize
    }
  }

  private func nominalFrameRate(of track: AVAssetTrack) async -> Float {
    if #available(iOS 15.0, macOS 13.0, *) {
      return (try? await track.load(.nominalFrameRate)) ?? 30
    } else {
      return track.nominalFrameRate
    }
  }
}
