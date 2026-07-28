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

  /// Stall bound for a render encode. A gated encode that makes no forward
  /// progress for this long (a wedged VideoToolbox session sitting at
  /// `progress == 0`) is force-cancelled so it releases its ``ExportGate`` slot
  /// instead of holding it forever and deadlocking every later export. Renders
  /// have no fixed upper length, so only the stall bound applies (no hard
  /// timeout) — a slow-but-progressing long render is never killed.
  static let renderStallTimeout: TimeInterval = 20

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
        guard !config.videoClips.isEmpty || config.composition != nil else {
          onError(
            NSError(
              domain: "RenderVideo",
              code: 1,
              userInfo: [NSLocalizedDescriptionKey: "Video clips cannot be empty"]
            ))
          return
        }

        // Bitrate-cap fast path: a no-edit export whose source already fits
        // the cap (× tolerance) is remuxed losslessly (passthrough) instead
        // of re-encoded — the Darwin equivalent of Android's transmux fast
        // path. Over-cap or unprobeable sources fall through to the full
        // pipeline, where the cap is enforced by the AVAssetWriter path.
        // HEVC 10-bit/HDR sources are excluded so they keep their usual
        // H.264 8-bit SDR pre-transcode instead of being copied verbatim.
        if config.bitrate != nil, BitrateCapPolicy.isPassthroughEligible(config),
          await !MediaInfoExtractor.getVideoFormatInfo(config.videoClips[0].inputPath)
            .needsTranscodingForEffects()
        {
          let sourceBitrate = await MediaInfoExtractor.getVideoBitrate(
            config.videoClips[0].inputPath)
          if !BitrateCapPolicy.shouldForceEncode(
            requestedBitrate: config.bitrate, sourceBitrates: [sourceBitrate])
          {
            PluginLog.print(
              "🚀 Bitrate cap: source (\((sourceBitrate ?? 0) / 1000) kbps) within cap — "
                + "lossless passthrough export")
            do {
              let data = try await passthroughExport(
                config: config, handle: handle, onProgress: onProgress)
              onComplete(data)
              return
            } catch {
              if Task.isCancelled || error is CancellationError {
                onError(error)
                return
              }
              PluginLog.print(
                "⚠️ Passthrough export failed (\(error.localizedDescription)) — "
                  + "falling back to full render")
            }
          } else {
            PluginLog.print(
              "📊 Bitrate cap: source (\((sourceBitrate ?? 0) / 1000) kbps) exceeds cap — "
                + "video will be re-encoded")
          }
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
                transition: clip.transition,
                chromaKey: clip.chromaKey
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
        // composition still sees plain forward clips. An overlap transition on
        // the last/only clip wraps into the first clip for a seamless loop and
        // is baked the same way, so a single clip can also need this stage.
        if workingConfig.videoClips.contains(where: { $0.transition?.isOverlap == true }) {
          let (newClips, urls) = await preRenderTransitions(
            clips: workingConfig.videoClips,
            enableAudio: workingConfig.enableAudio,
            outputFormat: workingConfig.outputFormat)
          workingConfig = workingConfig.copyWith(videoClips: newClips)
          transitionURLs = urls
        }

        do {
          outputURL = resolveOutputURL(
            outputPath: workingConfig.outputPath, format: workingConfig.outputFormat)

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

          // Build the composition: layered (multi-track) when a composition is
          // provided, otherwise the single-track concatenation path.
          let buildResult:
            (
              AVMutableComposition, VideoCompositionData, CGSize, AVAudioMix?, CMPersistentTrackID,
              [URL], [FadeWindow], [ChromaKeyWindow]
            )
          if let compositionConfig = workingConfig.composition {
            buildResult = try await LayeredCompositionBuilder(composition: compositionConfig)
              .setEnableAudio(workingConfig.enableAudio)
              .setAudioTracks(workingConfig.audioTracks)
              .setChromaKey(workingConfig.chromaKey)
              .build()
          } else {
            buildResult = try await applyComposition(
              videoClips: workingConfig.videoClips,
              videoEffects: effectsConfig,
              enableAudio: workingConfig.enableAudio,
              audioTracks: workingConfig.audioTracks,
              trimToCommonTrackEnd: workingConfig.trimToCommonTrackEnd,
              chromaKey: workingConfig.chromaKey
            )
          }
          let (
            composition, videoCompData, renderSize, audioMix, sourceTrackID, audioTempURLs,
            fadeWindows, chromaKeyWindows
          ) = buildResult
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

          // Get the first video track for orientation info. The layered path
          // handles each layer's orientation itself, so global orientation
          // correction is only needed for the single-track path.
          if workingConfig.composition == nil {
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
          }

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
          // Before applyColorMatrix, because the key must run on the original
          // colors — the compositor folds both into one color cube, since a
          // second CIColorCube would take its alpha from its own cube and
          // silently un-key the frame.
          applyChromaKey(config: &effectsConfig, windows: chromaKeyWindows)
          applyColorMatrix(
            config: &effectsConfig,
            filters: workingConfig.colorFilters)
          applyBlur(config: &effectsConfig, sigma: workingConfig.blur)
          // Total composition length, so layers that run "until the end"
          // (endUs == -1) with an out-phase animation get a concrete end to
          // animate toward instead of popping off at the last frame.
          let compositionTotalUs = Int64(CMTimeGetSeconds(composition.duration) * 1_000_000)
          applyImageLayer(
            config: &effectsConfig,
            imageLayers: workingConfig.imageLayers,
            withCropping: workingConfig.imageBytesWithCropping,
            totalDurationUs: compositionTotalUs)

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

          // A custom output resolution is the exact output canvas: the composed
          // frame is letterboxed into it (scaled to fit + centered + black
          // padding) by the compositor as its final step.
          if let target = workingConfig.outputResolution {
            finalRenderSize = target
            effectsConfig.outputResolution = target
          }

          // Cap the output frame rate when a maximum was requested. The
          // builders derive frameDuration from the source fps; lower the rate
          // only when it exceeds the cap, so a slower source is left untouched.
          var outputFrameDuration = videoCompConfig.frameDuration
          if let maxFps = workingConfig.maxFrameRate, maxFps > 0 {
            let current = outputFrameDuration
            let currentFps =
              current.value > 0 && current.timescale > 0
              ? Double(current.timescale) / Double(current.value)
              : Double(maxFps)
            if Double(maxFps) < currentFps {
              outputFrameDuration = CMTime(value: 1, timescale: CMTimeScale(maxFps))
            }
          }

          // Build the final AVMutableVideoComposition
          let videoComposition = AVMutableVideoComposition()
          videoComposition.frameDuration = outputFrameDuration
          videoComposition.renderSize = finalRenderSize
          videoComposition.instructions = videoCompConfig.instructions
          videoComposition.customVideoCompositorClass = makeVideoCompositorSubclass(
            with: effectsConfig)

          if let cap = workingConfig.bitrate {
            // A bitrate cap can only be honored by writing the video track
            // ourselves: AVAssetExportSession presets pick their own bitrate
            // and overshoot the request (a 1080p preset encodes 10-16 Mbit/s).
            PluginLog.print(
              "📊 Bitrate cap \(cap / 1000) kbps: rendering via AVAssetWriter "
                + "(AVVideoAverageBitRateKey)")
            let timeRange = try await resolveTrimTimeRange(
              composition: composition,
              startUs: workingConfig.startUs,
              endUs: workingConfig.endUs)
            let hasAudioTracks = !composition.tracks(withMediaType: .audio).isEmpty
            // Serialize against other encodes (concurrent renders/splits) so
            // they don't starve each other on the hardware encoder, and guard
            // the encode with a stall watchdog so a wedged session releases the
            // gate slot instead of deadlocking every later export.
            try await withExportSlot {
              try await ExportWatchdog.run(
                diagnostics: RenderExportDiagnostics(mode: "bitrate-capped", bitrate: cap),
                exportTimeout: 0,
                stallTimeout: renderStallTimeout,
                onProgress: onProgress,
                cancel: {},  // BitrateCappedExporter unwinds via task cancellation
                body: { progress in
                  try await BitrateCappedExporter.export(
                    asset: composition,
                    videoComposition: videoComposition,
                    audioMix: hasAudioTracks ? audioMix : nil,
                    outputURL: outputURL,
                    fileType: mapFormatToMimeType(format: workingConfig.outputFormat),
                    videoBitrate: cap,
                    timeRange: timeRange,
                    optimizeForNetworkUse: workingConfig.shouldOptimizeForNetworkUse,
                    onProgress: progress)
                })
            }
          } else {
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

            // Serialize against other encodes (concurrent renders/splits) so
            // they don't starve each other on the hardware encoder, and guard
            // the encode with a stall watchdog so a wedged session releases the
            // gate slot instead of deadlocking every later export.
            try await withExportSlot {
              try await ExportWatchdog.run(
                diagnostics: RenderExportDiagnostics(mode: preset, bitrate: nil),
                exportTimeout: 0,
                stallTimeout: renderStallTimeout,
                onProgress: onProgress,
                cancel: { export.cancelExport() },
                body: { progress in
                  try await monitorExportProgress(export, onProgress: progress)
                })
            }
          }

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
    // A random suffix keeps concurrent renders from colliding on the same
    // millisecond timestamp.
    let random = UInt32.random(in: 0...UInt32.max)
    return "\(prefix)_\(timestamp)_\(random).\(ext)"
  }

  private static func temporaryURL(for format: String) -> URL {
    let filename = uniqueFilename(prefix: "output", extension: format)
    return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
  }

  /// Resolves the destination URL, correcting a mismatched file extension, or
  /// creates a temporary URL when no output path was requested.
  private static func resolveOutputURL(outputPath: String?, format: String) -> URL {
    guard let outputPath = outputPath else {
      return temporaryURL(for: format)
    }
    let url = URL(fileURLWithPath: outputPath)
    let pathExtension = url.pathExtension.lowercased()
    let requestedFormat = format.lowercased()

    if pathExtension != requestedFormat {
      PluginLog.print(
        "⚠️ WARNING: Output path extension '.\(pathExtension)' doesn't match requested format '.\(requestedFormat)'"
      )
      PluginLog.print("⚠️ Correcting file extension to match format...")
      return url.deletingPathExtension().appendingPathExtension(requestedFormat)
    }
    return url
  }

  // MARK: - Bitrate-cap passthrough export

  /// Losslessly remuxes a single no-edit clip with
  /// `AVAssetExportPresetPassthrough` (no re-encode), preserving
  /// `shouldOptimizeForNetworkUse`. Throws when the source cannot be written
  /// into the requested container — the caller falls back to the full render
  /// pipeline in that case.
  private static func passthroughExport(
    config: RenderConfig,
    handle: RenderJobHandle,
    onProgress: @escaping (Double) -> Void
  ) async throws -> Data? {
    let outputURL = resolveOutputURL(
      outputPath: config.outputPath, format: config.outputFormat)
    let asset = AVURLAsset(url: URL(fileURLWithPath: config.videoClips[0].inputPath))
    guard
      let export = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPresetPassthrough)
    else {
      throw NSError(
        domain: "RenderVideo", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Passthrough session creation failed"])
    }

    try? FileManager.default.removeItem(at: outputURL)
    export.outputURL = outputURL
    export.outputFileType = mapFormatToMimeType(format: config.outputFormat)
    export.shouldOptimizeForNetworkUse = config.shouldOptimizeForNetworkUse
    // Attached before the track loads below so a cancel arriving during them
    // is still honoured; `export()` only starts in `monitorExportProgress`.
    handle.attach(export: export)

    // This fast path skips the composition entirely, so it has to apply the
    // common-track-end trim itself — otherwise the flag would be a silent
    // no-op for exactly the single untrimmed clip it targets. Passthrough
    // honours `timeRange` frame-accurately (same as the split fast path), so
    // the export stays lossless.
    if config.trimToCommonTrackEnd, config.enableAudio,
      let trimmed = await TrackEndTrimmer.trimmedAssetRange(of: asset, label: "Passthrough")
    {
      export.timeRange = trimmed
      PluginLog.print(
        "   ✂️ Passthrough trimmed to common track end: "
          + "\(String(format: "%.3f", trimmed.duration.seconds))s")
    }

    do {
      try await monitorExportProgress(export, onProgress: onProgress)
    } catch {
      // Never leave a partial file behind; the fallback re-creates it.
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }

    if config.outputPath != nil {
      return nil
    }
    let data = try Data(contentsOf: outputURL)
    try? FileManager.default.removeItem(at: outputURL)
    return data
  }

  /// Resolves the global trim (startUs/endUs) into a clamped time range, or
  /// nil when no trim was requested or the range is empty.
  private static func resolveTrimTimeRange(
    composition: AVAsset,
    startUs: Int64?,
    endUs: Int64?
  ) async throws -> CMTimeRange? {
    guard startUs != nil || endUs != nil else { return nil }

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

    guard CMTimeGetSeconds(clampedDuration) > 0 else { return nil }
    return CMTimeRange(start: startTime, duration: clampedDuration)
  }

  // MARK: - Overlap transition pre-render

  /// Pre-renders overlap transitions (dissolve/slide/push/wipe) into short
  /// blended clips and rewrites the clip list, mirroring the Android pipeline.
  ///
  /// For a transition between clip *i* and *i+1*, `ClipTransitionGeometry`
  /// resolves the blend in OUTPUT (post-speed) time: clip *i* is shortened by
  /// `output * speed_i` of source, the blended clip (output duration) is
  /// inserted, and clip *i+1*'s head is trimmed by `output * speed_{i+1}` of
  /// source. The blend itself is rendered at the requested speed for each side,
  /// so footage inside the transition plays at the same speed as the rest of
  /// the clip. Falls back to a hard cut when a transition cannot be rendered
  /// (e.g. a neighbour is reversed or has too little content) — those cases are
  /// handled live by the main pipeline.
  private static func preRenderTransitions(
    clips: [VideoClip], enableAudio: Bool, outputFormat: String
  ) async -> ([VideoClip], [URL]) {
    // An overlap transition on the last/only clip loops back into the first clip
    // (seamless loop). Captured before the between-clip pass clears it.
    let wrapTransition: ClipTransitionConfig? = {
      guard let t = clips.last?.transition, t.isOverlap,
        !(clips.last?.reverseVideo ?? false), !(clips.first?.reverseVideo ?? false)
      else { return nil }
      return t
    }()

    var work = clips
    var result: [VideoClip] = []
    var urls: [URL] = []
    var i = 0

    // Append an original clip only if it still has positive duration. A blend
    // can consume a neighbouring clip entirely (two adjacent transitions sharing
    // a clip), leaving a zero-length body — drop it and let the blend clip take
    // its place rather than feed a zero-length clip to the composer.
    func appendClip(_ clip: VideoClip) {
      let start = clip.startUs ?? 0
      if let end = clip.endUs, end <= start { return }
      result.append(clip)
    }

    while i < work.count {
      let current = work[i]
      let next: VideoClip? = (i + 1 < work.count) ? work[i + 1] : nil
      let t = current.transition

      let canOverlap =
        next != nil && (t?.isOverlap ?? false)
        && !current.reverseVideo && !(next!.reverseVideo)

      if !canOverlap {
        appendClip(clearedOverlap(current))
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

      // Resolve the overlap geometry in OUTPUT (post-speed) time so the
      // requested transition duration matches the non-transition timeline and
      // each side consumes `output * speed` of its own source.
      guard
        let plan = ClipTransitionGeometry.planOverlap(
          outgoingSourceDurationUs: curDur,
          incomingSourceDurationUs: nextDur,
          transitionDurationUs: t!.durationUs,
          outgoingSpeed: current.playbackSpeed,
          incomingSpeed: next!.playbackSpeed)
      else {
        PluginLog.print("⚠️ Transition: not enough content at boundary \(i); hard cut")
        appendClip(clearedOverlap(current))
        i += 1
        continue
      }

      let tailSrc = plan.outgoingTailSourceUs
      let headSrc = plan.incomingHeadSourceUs

      let includeAudio =
        enableAudio && (current.volume ?? 1.0) > 0 && (next!.volume ?? 1.0) > 0
      let rendered = await ClipTransitionRenderer.render(
        outgoingPath: current.inputPath,
        outTailStartUs: curEnd - tailSrc, outTailEndUs: curEnd,
        incomingPath: next!.inputPath,
        inHeadStartUs: nextStart, inHeadEndUs: nextStart + headSrc,
        outputDurationUs: plan.outputDurationUs,
        type: t!.type, direction: t!.direction, curve: t!.curve,
        includeAudio: includeAudio, outputFormat: outputFormat)

      if let rendered = rendered {
        urls.append(rendered.outputURL)
        // Keep the outgoing clip's speed; it now ends `tailSrc` of source
        // earlier (those frames moved into the speed-adjusted blend).
        appendClip(
          VideoClip(
            inputPath: current.inputPath, startUs: curStart, endUs: curEnd - tailSrc,
            volume: current.volume, playbackSpeed: current.playbackSpeed,
            reverseVideo: false, transition: nil, chromaKey: current.chromaKey))
        result.append(
          VideoClip(
            inputPath: rendered.outputURL.path, startUs: 0, endUs: rendered.durationUs,
            chromaKey: blendChromaKey(current, next!, boundary: "\(i)")))
        // Trim the incoming head in place; it keeps its own speed/transition.
        work[i + 1] = VideoClip(
          inputPath: next!.inputPath, startUs: nextStart + headSrc, endUs: nextEnd,
          volume: next!.volume, playbackSpeed: next!.playbackSpeed,
          reverseVideo: next!.reverseVideo, transition: next!.transition,
          chromaKey: next!.chromaKey)
      } else {
        PluginLog.print("⚠️ Transition render failed at boundary \(i); hard cut")
        appendClip(clearedOverlap(current))
      }
      i += 1
    }

    // Wrap pass: render the last clip's tail dissolving into the first clip's
    // head and append it, so any looping player restarts seamlessly. The
    // between-clip pass only inserts blends *between* clips, so result's first
    // and last entries are still the original first/last clips.
    if let wrap = wrapTransition, !result.isEmpty {
      let lastIdx = result.count - 1
      let first = result[0]
      let last = result[lastIdx]
      let singleClip = lastIdx == 0

      let firstStart = first.startUs ?? 0
      let lastStart = last.startUs ?? 0
      let lastEnd: Int64
      if let e = last.endUs {
        lastEnd = e
      } else {
        lastEnd = await clipDurationUs(last.inputPath)
      }

      // Single-clip loops carve head and tail from the same source, so they need
      // the stricter head+tail<L guard; multi-clip loops keep two independent
      // sources and reuse the ordinary overlap geometry.
      let plan: ClipTransitionGeometry.OverlapPlan?
      if singleClip {
        plan = ClipTransitionGeometry.planWrap(
          sourceDurationUs: lastEnd - lastStart,
          transitionDurationUs: wrap.durationUs,
          speed: last.playbackSpeed)
      } else {
        let firstEnd: Int64
        if let e = first.endUs {
          firstEnd = e
        } else {
          firstEnd = await clipDurationUs(first.inputPath)
        }
        plan = ClipTransitionGeometry.planOverlap(
          outgoingSourceDurationUs: lastEnd - lastStart,
          incomingSourceDurationUs: firstEnd - firstStart,
          transitionDurationUs: wrap.durationUs,
          outgoingSpeed: last.playbackSpeed,
          incomingSpeed: first.playbackSpeed)
      }

      if let plan = plan {
        let tailSrc = plan.outgoingTailSourceUs
        let headSrc = plan.incomingHeadSourceUs
        let includeAudio =
          enableAudio && (last.volume ?? 1.0) > 0 && (first.volume ?? 1.0) > 0
        let rendered = await ClipTransitionRenderer.render(
          outgoingPath: last.inputPath,
          outTailStartUs: lastEnd - tailSrc, outTailEndUs: lastEnd,
          incomingPath: first.inputPath,
          inHeadStartUs: firstStart, inHeadEndUs: firstStart + headSrc,
          outputDurationUs: plan.outputDurationUs,
          type: wrap.type, direction: wrap.direction, curve: wrap.curve,
          includeAudio: includeAudio, outputFormat: outputFormat)

        if let rendered = rendered {
          urls.append(rendered.outputURL)
          if singleClip {
            // Trim both ends of the one clip; the carved head/tail moved into
            // the appended blend.
            result[0] = VideoClip(
              inputPath: first.inputPath, startUs: firstStart + headSrc,
              endUs: lastEnd - tailSrc, volume: first.volume,
              playbackSpeed: first.playbackSpeed, reverseVideo: false, transition: nil,
              chromaKey: first.chromaKey)
          } else {
            result[0] = VideoClip(
              inputPath: first.inputPath, startUs: firstStart + headSrc,
              endUs: first.endUs, volume: first.volume,
              playbackSpeed: first.playbackSpeed, reverseVideo: false,
              transition: first.transition, chromaKey: first.chromaKey)
            result[lastIdx] = VideoClip(
              inputPath: last.inputPath, startUs: last.startUs, endUs: lastEnd - tailSrc,
              volume: last.volume, playbackSpeed: last.playbackSpeed,
              reverseVideo: false, transition: nil, chromaKey: last.chromaKey)
          }
          result.append(
            VideoClip(
              inputPath: rendered.outputURL.path, startUs: 0, endUs: rendered.durationUs,
              chromaKey: blendChromaKey(last, first, boundary: "loop wrap")))
        } else {
          PluginLog.print("⚠️ Loop wrap render failed; seamless loop skipped")
        }
      } else {
        PluginLog.print("⚠️ Loop wrap: not enough content; seamless loop skipped")
      }
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
      reverseVideo: clip.reverseVideo, transition: nil, chromaKey: clip.chromaKey)
  }

  /// The chroma key to apply to a pre-rendered overlap blend.
  ///
  /// The blend is composed from the raw sources by `ClipTransitionRenderer`,
  /// which knows nothing about keying, so the key has to be re-applied to its
  /// output. That only has a defined meaning when both sides key the same way:
  /// blending a keyed clip with an unkeyed one produces mixed colors that no
  /// single key can undo. Mismatched sides are therefore left unkeyed and
  /// reported, rather than silently keyed with one side's settings.
  private static func blendChromaKey(
    _ outgoing: VideoClip, _ incoming: VideoClip, boundary: String
  ) -> ChromaKeyConfig? {
    if outgoing.chromaKey == incoming.chromaKey { return outgoing.chromaKey }
    PluginLog.print(
      "⚠️ Chroma key: the two clips at boundary \(boundary) use different keys; "
        + "the pre-rendered transition blend is emitted unkeyed")
    return nil
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
    if let timeRange = try await resolveTrimTimeRange(
      composition: composition, startUs: startUs, endUs: endUs)
    {
      export.timeRange = timeRange
      PluginLog.print(
        "   - TimeRange applied: \(String(format: "%.2f", CMTimeGetSeconds(timeRange.start)))s - \(String(format: "%.2f", CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange))))s"
      )
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

/// Diagnostic context for a render encode, mirroring ``SplitExportDiagnostics``
/// so a stall/timeout surfaces the same shape of message on the render path.
struct RenderExportDiagnostics: ExportDiagnostics {
  /// What is being encoded — `"bitrate-capped"` for the AVAssetWriter path or
  /// the export-session preset name.
  let mode: String
  /// Requested video bitrate in bits/s, or nil for a preset export.
  let bitrate: Int?

  /// e.g. `[progress=0.00 mode=bitrate-capped bitrate=4000kbps]`
  func context(progress: Double) -> String {
    let bitrateText = bitrate.map { "\($0 / 1000)kbps" } ?? "preset"
    return String(
      format: "[progress=%.2f mode=%@ bitrate=%@]", progress, mode, bitrateText)
  }

  func timeoutMessage(seconds: Int, progress: Double) -> String {
    "Render export timed out after \(seconds)s \(context(progress: progress))"
  }

  func stallMessage(seconds: Int, progress: Double) -> String {
    "Render export stalled after \(seconds)s with no progress \(context(progress: progress))"
  }
}
