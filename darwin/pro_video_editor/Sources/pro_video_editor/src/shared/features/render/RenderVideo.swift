import AVFoundation
import CoreImage
import Foundation

#if os(macOS)
  import AppKit
#endif

/// Service for rendering video with applied effects and transformations.
///
/// This class handles the complete video rendering pipeline using AVFoundation:
/// - Supports multiple video clips concatenation
/// - Applies visual effects (rotation, flip, crop, scale, color matrix, blur)
/// - Manages audio mixing (original audio volume + custom audio track)
/// - Supports playback speed adjustment
/// - Provides progress tracking during rendering
/// - Supports cancellation of active render jobs
///
/// All rendering operations are performed asynchronously on a dedicated queue.
class RenderVideo {
  static let queue = DispatchQueue(label: "RenderVideoQueue")

  // MARK: - Public Methods

  /// Starts an asynchronous video render job using RenderConfig.
  @discardableResult
  static func render(
    config: RenderConfig,
    onProgress: @escaping (Double) -> Void,
    onComplete: @escaping (Data?) -> Void,
    onError: @escaping (Error) -> Void
  ) -> RenderJobHandle {
    let handle = RenderJobHandle()
    queue.async {
      let renderTask = Task {
        guard !config.videoClips.isEmpty else {
          onError(
            NSError(
              domain: "RenderVideo",
              code: 1,
              userInfo: [NSLocalizedDescriptionKey: "Video clips cannot be empty"]
            ))
          return
        }

        var transcodedFiles: [String] = []
        var workingConfig = config

        // HEVC 10-bit HDR videos cause issues with AVFoundation's compositor
        // They must be pre-transcoded to H.264 8-bit SDR for ANY effect processing
        PluginLog.print("🔍 Checking for HEVC 10-bit videos that need transcoding...")

        // Pre-transcode HEVC 10-bit HDR videos to H.264 8-bit SDR
        let inputPaths = config.videoClips.map { $0.inputPath }
        let transcodeMap = await VideoTranscoder.transcodeClipsIfNeeded(inputPaths)

        // Track transcoded files for cleanup
        transcodedFiles = transcodeMap.values.filter { $0.contains("transcoded_") }

        if !transcodedFiles.isEmpty {
          PluginLog.print("✅ Pre-transcoded \(transcodedFiles.count) HEVC 10-bit videos to H.264")

          // Update config with transcoded paths
          let updatedClips = config.videoClips.map { clip -> VideoClip in
            if let newPath = transcodeMap[clip.inputPath], newPath != clip.inputPath {
              return VideoClip(
                inputPath: newPath,
                startUs: clip.startUs,
                endUs: clip.endUs,
                volume: clip.volume,
                playbackSpeed: clip.playbackSpeed,
                reverseVideo: clip.reverseVideo,
                transition: clip.transition
              )
            }
            return clip
          }

          // Create new config with updated clips
          workingConfig = config.copyWith(videoClips: updatedClips)
        }

        var outputURL: URL!
        var temporaryAudioURLs: [URL] = []
        var transitionURLs: [URL] = []

        let finalize: () -> Void = {
          try? cleanup(config.outputPath == nil ? [outputURL] : [])
          // Clean up transcoded files
          VideoTranscoder.cleanupTranscodedFiles(transcodedFiles)
          // Clean up pre-rendered audio temp files
          for url in temporaryAudioURLs {
            try? FileManager.default.removeItem(at: url)
            PluginLog.print("🧹 Removed pre-rendered audio: \(url.lastPathComponent)")
          }
          // Clean up pre-rendered overlap transition clips
          for url in transitionURLs {
            try? FileManager.default.removeItem(at: url)
            PluginLog.print("🧹 Removed transition clip: \(url.lastPathComponent)")
          }
        }

        let handleCompletion: (Result<Data?, Error>) -> Void = { result in
          switch result {
          case .success(let data): onComplete(data)
          case .failure(let error): onError(error)
          }
          finalize()
        }

        // Pre-render overlap clip transitions (dissolve/slide/push/wipe) into
        // short blended clips spliced between the neighbours, so the main
        // composition still sees plain forward clips.
        if workingConfig.videoClips.count > 1,
          workingConfig.videoClips.contains(where: { $0.transition?.isOverlap == true })
        {
          let (newClips, urls) = await preRenderTransitions(
            clips: workingConfig.videoClips,
            enableAudio: workingConfig.enableAudio,
            outputFormat: workingConfig.outputFormat)
          workingConfig = workingConfig.copyWith(videoClips: newClips)
          transitionURLs = urls
        }

        do {
          if let outputPath = workingConfig.outputPath {
            // Ensure file extension matches the requested format
            let url = URL(fileURLWithPath: outputPath)
            let pathExtension = url.pathExtension.lowercased()
            let requestedFormat = workingConfig.outputFormat.lowercased()

            if pathExtension != requestedFormat {
              PluginLog.print(
                "⚠️ WARNING: Output path extension '.\(pathExtension)' doesn't match requested format '.\(requestedFormat)'"
              )
              PluginLog.print("⚠️ Correcting file extension to match format...")

              // Replace extension with correct format
              let pathWithoutExtension = url.deletingPathExtension()
              outputURL = pathWithoutExtension.appendingPathExtension(requestedFormat)
            } else {
              outputURL = url
            }
          } else {
            outputURL = temporaryURL(for: workingConfig.outputFormat)
          }

          PluginLog.print("")
          PluginLog.print("🎬 ===== RENDER CONFIG =====")
          PluginLog.print("   Video clips: \(workingConfig.videoClips.count)")
          PluginLog.print("   📁 Output format: \(workingConfig.outputFormat)")
          PluginLog.print("   📹 Output path: \(outputURL.path)")
          PluginLog.print("   🔊 Enable Audio: \(workingConfig.enableAudio)")
          PluginLog.print("   🎵 Audio tracks: \(workingConfig.audioTracks.count)")
          PluginLog.print("   🎨 Color filters: \(workingConfig.colorFilters.count)")
          PluginLog.print("===========================")
          PluginLog.print("")

          // Create configuration for video effects
          var effectsConfig = VideoCompositorConfig()

          // Use composition helper to merge multiple video clips
          let (
            composition, videoCompData, renderSize, audioMix, sourceTrackID, audioTempURLs,
            fadeWindows
          ) =
            try await applyComposition(
              videoClips: workingConfig.videoClips,
              videoEffects: effectsConfig,
              enableAudio: workingConfig.enableAudio,
              audioTracks: workingConfig.audioTracks
            )
          temporaryAudioURLs = audioTempURLs
          var videoCompConfig = videoCompData

          // Set source track ID for fallback on older platform variations
          effectsConfig.sourceTrackID = sourceTrackID

          // Dip-to-color (fade-to-black / fade-to-white) clip transitions.
          effectsConfig.fadeWindows = fadeWindows

          // Apply playback speed to the entire composition
          videoCompConfig.instructions = applyPlaybackSpeed(
            composition: composition, instructions: videoCompConfig.instructions,
            speed: workingConfig.playbackSpeed)

          // Get the first video track for orientation info
          let firstClipURL = URL(fileURLWithPath: workingConfig.videoClips[0].inputPath)
          let firstAsset = AVURLAsset(url: firstClipURL)
          let videoTrack = try await loadVideoTrack(from: firstAsset)

          let preferredTransform: CGAffineTransform
          if #available(iOS 15.0, macOS 13.0, *) {
            preferredTransform = try await videoTrack.load(.preferredTransform)
          } else {
            preferredTransform = videoTrack.preferredTransform
          }

          let videoRotationDegrees = extractRotationFromTransform(preferredTransform)
          effectsConfig.videoRotationDegrees = videoRotationDegrees
          effectsConfig.shouldApplyOrientationCorrection = abs(videoRotationDegrees) > 1.0
          effectsConfig.originalNaturalSize = videoTrack.naturalSize

          let croppedSize = applyCrop(
            config: &effectsConfig,
            naturalSize: renderSize,
            rotateTurns: workingConfig.rotateTurns,
            cropX: workingConfig.cropX,
            cropY: workingConfig.cropY,
            cropWidth: workingConfig.cropWidth,
            cropHeight: workingConfig.cropHeight
          )

          applyRotation(config: &effectsConfig, rotateTurns: workingConfig.rotateTurns)
          applyFlip(
            config: &effectsConfig, flipX: workingConfig.flipX,
            flipY: workingConfig.flipY)
          applyScale(
            config: &effectsConfig, scaleX: workingConfig.scaleX,
            scaleY: workingConfig.scaleY)
          applyColorMatrix(
            config: &effectsConfig,
            filters: workingConfig.colorFilters)
          applyBlur(config: &effectsConfig, sigma: workingConfig.blur)
          applyImageLayer(
            config: &effectsConfig,
            imageLayers: workingConfig.imageLayers,
            withCropping: workingConfig.imageBytesWithCropping)

          var finalRenderSize = videoCompConfig.renderSize

          // Only update renderSize if cropping was actually applied
          if workingConfig.cropWidth != nil || workingConfig.cropHeight != nil {
            finalRenderSize = croppedSize
          } else {
            if let rotateTurns = workingConfig.rotateTurns {
              let normalizedRotation = (rotateTurns % 4 + 4) % 4
              if normalizedRotation == 1 || normalizedRotation == 3 {
                finalRenderSize = CGSize(
                  width: finalRenderSize.height,
                  height: finalRenderSize.width
                )
              }
            }
          }

          let effectiveScaleX = workingConfig.scaleX ?? 1.0
          let effectiveScaleY = workingConfig.scaleY ?? 1.0

          if effectiveScaleX != 1.0 || effectiveScaleY != 1.0 {
            finalRenderSize = CGSize(
              width: finalRenderSize.width * CGFloat(effectiveScaleX),
              height: finalRenderSize.height * CGFloat(effectiveScaleY)
            )
          } else if effectsConfig.scaleX != 1.0 || effectsConfig.scaleY != 1.0 {
            finalRenderSize = CGSize(
              width: finalRenderSize.width * effectsConfig.scaleX,
              height: finalRenderSize.height * effectsConfig.scaleY
            )
          }

          // Build the final AVMutableVideoComposition
          let videoComposition = AVMutableVideoComposition()
          videoComposition.frameDuration = videoCompConfig.frameDuration
          videoComposition.renderSize = finalRenderSize
          videoComposition.instructions = videoCompConfig.instructions
          videoComposition.customVideoCompositorClass = makeVideoCompositorSubclass(
            with: effectsConfig)

          let preset = applyBitrate(requestedBitrate: workingConfig.bitrate)

          let export = try await prepareExportSession(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            outputURL: outputURL,
            outputFormat: workingConfig.outputFormat,
            preset: preset,
            startUs: workingConfig.startUs,
            endUs: workingConfig.endUs,
            shouldOptimizeForNetworkUse: workingConfig.shouldOptimizeForNetworkUse
          )

          handle.attach(export: export)

          try await monitorExportProgress(export, onProgress: onProgress)

          if workingConfig.outputPath != nil {
            handleCompletion(.success(nil))
          } else {
            let data = try Data(contentsOf: outputURL)
            handleCompletion(.success(data))
          }
        } catch {
          handleCompletion(.failure(error))
        }
      }
      handle.attach(task: renderTask)
    }

    return handle
  }

  // MARK: - Helper Methods

  private static func hasGpuIntensiveEffects(_ config: RenderConfig) -> Bool {
    let hasImageOverlay = !config.imageLayers.isEmpty
    let hasBlur = config.blur != nil && config.blur! > 0
    let hasColorFilter = !config.colorFilters.isEmpty
    return hasImageOverlay || hasBlur || hasColorFilter
  }

  private static func makeVideoCompositorSubclass(with config: VideoCompositorConfig)
    -> AVVideoCompositing.Type
  {
    class CustomCompositor: VideoCompositor {}
    CustomCompositor.config = config
    return CustomCompositor.self
  }

  private static func uniqueFilename(prefix: String, extension ext: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
    let timestamp = formatter.string(from: Date())
    return "\(prefix)_\(timestamp).\(ext)"
  }

  private static func temporaryURL(for format: String) -> URL {
    let filename = uniqueFilename(prefix: "output", extension: format)
    return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
  }

  // MARK: - Overlap transition pre-render

  /// Pre-renders overlap transitions (dissolve/slide/push/wipe) into short
  /// blended clips and rewrites the clip list, mirroring the Android pipeline.
  ///
  /// For a transition between clip *i* and *i+1*, clip *i* is shortened by the
  /// (clamped) transition duration `d`, the blended clip (`d`) is inserted, and
  /// clip *i+1*'s head is trimmed by `d`. Net timeline change: `-d` per
  /// transition. Falls back to a hard cut when a transition cannot be rendered
  /// (e.g. a neighbour is reversed, has per-clip speed, or has too little
  /// content) — those cases are handled live by the main pipeline.
  private static func preRenderTransitions(
    clips: [VideoClip], enableAudio: Bool, outputFormat: String
  ) async -> ([VideoClip], [URL]) {
    var work = clips
    var result: [VideoClip] = []
    var urls: [URL] = []
    var i = 0

    while i < work.count {
      let current = work[i]
      let next: VideoClip? = (i + 1 < work.count) ? work[i + 1] : nil
      let t = current.transition

      let canOverlap =
        next != nil && (t?.isOverlap ?? false)
        && !current.reverseVideo && !(next!.reverseVideo)
        && (current.playbackSpeed == nil || current.playbackSpeed == 1.0)
        && (next!.playbackSpeed == nil || next!.playbackSpeed == 1.0)

      if !canOverlap {
        result.append(clearedOverlap(current))
        i += 1
        continue
      }

      let curStart = current.startUs ?? 0
      let curEnd: Int64
      if let e = current.endUs {
        curEnd = e
      } else {
        curEnd = await clipDurationUs(current.inputPath)
      }
      let nextStart = next!.startUs ?? 0
      let nextEnd: Int64
      if let e = next!.endUs {
        nextEnd = e
      } else {
        nextEnd = await clipDurationUs(next!.inputPath)
      }
      let curDur = curEnd - curStart
      let nextDur = nextEnd - nextStart
      let d = min(t!.durationUs, min(curDur, nextDur))

      if d <= 0 || curDur - d <= 0 || nextDur - d <= 0 {
        PluginLog.print("⚠️ Transition: not enough content at boundary \(i); hard cut")
        result.append(clearedOverlap(current))
        i += 1
        continue
      }

      let includeAudio =
        enableAudio && (current.volume ?? 1.0) > 0 && (next!.volume ?? 1.0) > 0
      let rendered = await ClipTransitionRenderer.render(
        outgoingPath: current.inputPath,
        outTailStartUs: curEnd - d, outTailEndUs: curEnd,
        incomingPath: next!.inputPath,
        inHeadStartUs: nextStart, inHeadEndUs: nextStart + d,
        type: t!.type, direction: t!.direction, curve: t!.curve,
        includeAudio: includeAudio, outputFormat: outputFormat)

      if let rendered = rendered {
        urls.append(rendered.outputURL)
        result.append(
          VideoClip(
            inputPath: current.inputPath, startUs: curStart, endUs: curEnd - d,
            volume: current.volume, playbackSpeed: current.playbackSpeed,
            reverseVideo: false, transition: nil))
        result.append(
          VideoClip(
            inputPath: rendered.outputURL.path, startUs: 0, endUs: rendered.durationUs))
        // Trim the incoming head in place; it keeps its own transition.
        work[i + 1] = VideoClip(
          inputPath: next!.inputPath, startUs: nextStart + d, endUs: nextEnd,
          volume: next!.volume, playbackSpeed: next!.playbackSpeed,
          reverseVideo: next!.reverseVideo, transition: next!.transition)
      } else {
        PluginLog.print("⚠️ Transition render failed at boundary \(i); hard cut")
        result.append(clearedOverlap(current))
      }
      i += 1
    }

    return (result, urls)
  }

  /// Clears an overlap transition (already consumed / unsupported) so it is not
  /// reinterpreted downstream; dip transitions are left untouched.
  private static func clearedOverlap(_ clip: VideoClip) -> VideoClip {
    guard clip.transition?.isOverlap == true else { return clip }
    return VideoClip(
      inputPath: clip.inputPath, startUs: clip.startUs, endUs: clip.endUs,
      volume: clip.volume, playbackSpeed: clip.playbackSpeed,
      reverseVideo: clip.reverseVideo, transition: nil)
  }

  /// Loads a clip's total duration in microseconds.
  private static func clipDurationUs(_ path: String) async -> Int64 {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let dur: CMTime
    if #available(iOS 15.0, macOS 13.0, *) {
      dur = (try? await asset.load(.duration)) ?? .zero
    } else {
      dur = asset.duration
    }
    return Int64(CMTimeGetSeconds(dur) * 1_000_000)
  }

  private static func loadVideoTrack(from asset: AVAsset) async throws -> AVAssetTrack {
    if #available(iOS 15.0, macOS 13.0, *) {
      let tracks = try await asset.loadTracks(withMediaType: .video)
      guard let track = tracks.first else {
        throw NSError(
          domain: "RenderVideo", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "No video track found"])
      }
      return track
    } else {
      guard let track = asset.tracks(withMediaType: .video).first else {
        throw NSError(
          domain: "RenderVideo", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "No video track found"])
      }
      return track
    }
  }

  private static func extractRotationFromTransform(_ transform: CGAffineTransform) -> Double {
    let rotationAngle = atan2(transform.b, transform.a)
    return rotationAngle * 180 / Double.pi
  }

  private static func prepareExportSession(
    composition: AVAsset,
    videoComposition: AVVideoComposition,
    audioMix: AVAudioMix?,
    outputURL: URL,
    outputFormat: String,
    preset: String,
    startUs: Int64?,
    endUs: Int64?,
    shouldOptimizeForNetworkUse: Bool
  ) async throws -> AVAssetExportSession {
    guard let export = AVAssetExportSession(asset: composition, presetName: preset) else {
      throw NSError(
        domain: "RenderVideo", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Export session creation failed"])
    }

    let fileType = mapFormatToMimeType(format: outputFormat)
    PluginLog.print("📹 Export session setup:")
    PluginLog.print("   - Requested format: \(outputFormat)")
    PluginLog.print("   - AVFileType: \(fileType.rawValue)")
    PluginLog.print("   - Output URL: \(outputURL.path)")

    export.outputURL = outputURL
    export.outputFileType = fileType
    export.videoComposition = videoComposition

    // Apply global trim (timeRange) if startUs or endUs is provided
    if startUs != nil || endUs != nil {
      let compositionDuration: CMTime
      if #available(iOS 16.0, macOS 13.0, *) {
        compositionDuration = try await composition.load(.duration)
      } else {
        compositionDuration = composition.duration
      }
      let startTime = startUs.map { CMTime(value: $0, timescale: 1_000_000) } ?? .zero
      let endTime =
        endUs.map { CMTime(value: $0, timescale: 1_000_000) } ?? compositionDuration
      let duration = CMTimeSubtract(endTime, startTime)

      // Ensure we don't exceed composition bounds
      let clampedDuration = CMTimeMinimum(
        duration, CMTimeSubtract(compositionDuration, startTime))

      if CMTimeGetSeconds(clampedDuration) > 0 {
        export.timeRange = CMTimeRange(start: startTime, duration: clampedDuration)
        PluginLog.print(
          "   - TimeRange applied: \(String(format: "%.2f", CMTimeGetSeconds(startTime)))s - \(String(format: "%.2f", CMTimeGetSeconds(CMTimeAdd(startTime, clampedDuration))))s"
        )
      }
    }

    // Check if composition has audio tracks
    let hasAudioTracks =
      (composition as? AVMutableComposition)?.tracks(withMediaType: .audio).isEmpty == false

    // Apply audio mix if available
    if let audioMix = audioMix, hasAudioTracks {
      export.audioMix = audioMix
      PluginLog.print("🔊 Audio mix applied to export session")
    } else if !hasAudioTracks {
      PluginLog.print("ℹ️ No audio tracks in composition - exporting video only")
    }

    // Apply fast start optimization (moves moov atom to beginning for streaming)
    export.shouldOptimizeForNetworkUse = shouldOptimizeForNetworkUse
    if shouldOptimizeForNetworkUse {
      PluginLog.print("🚀 Fast start enabled - optimizing for network streaming")
    }

    return export
  }

  private static func monitorExportProgress(
    _ export: AVAssetExportSession,
    onProgress: @escaping (Double) -> Void
  ) async throws {
    let updateInterval: TimeInterval = 0.2
    if #available(iOS 18.0, macOS 15.0, *) {
      // Monitor progress in background using new async API
      let progressTask = Task {
        for try await state in export.states(updateInterval: updateInterval) {
          if case .exporting(let progress) = state {
            onProgress(progress.fractionCompleted)
          }
        }
      }

      // Start export using new async API (replaces deprecated exportAsynchronously)
      try await export.export(to: export.outputURL!, as: export.outputFileType!)

      // Ensure progress monitoring completes
      try await progressTask.value
    } else {
      let intervalNs = UInt64(updateInterval * 1_000_000_000)
      export.exportAsynchronously {}
      while export.status == .waiting || export.status == .exporting {
        if export.status == .exporting {
          let normalizedProgress = min(max(export.progress, 0), 1.0)
          onProgress(Double(normalizedProgress))
        }
        try await Task.sleep(nanoseconds: intervalNs)
      }

      guard export.status == .completed else {
        throw export.error
          ?? NSError(
            domain: "RenderVideo", code: 4,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Export failed with status \(export.status.rawValue)"
            ])
      }
    }
  }

  private static func cleanup(_ urls: [URL]) throws {
    for url in urls {
      try? FileManager.default.removeItem(at: url)
    }
  }
}

final class RenderJobHandle {
  private let lock = NSLock()
  private var exportSession: AVAssetExportSession?
  private var renderTask: Task<Void, Never>?
  private var canceled = false

  func attach(export: AVAssetExportSession) {
    lock.lock()
    defer { lock.unlock() }
    exportSession = export
    if canceled {
      export.cancelExport()
    }
  }

  func attach(task: Task<Void, Never>) {
    lock.lock()
    defer { lock.unlock() }
    renderTask = task
    if canceled {
      task.cancel()
    }
  }

  func cancel() {
    lock.lock()
    canceled = true
    let session = exportSession
    let task = renderTask
    lock.unlock()

    task?.cancel()
    session?.cancelExport()
  }
}
