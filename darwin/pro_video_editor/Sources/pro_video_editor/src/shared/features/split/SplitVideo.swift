import AVFoundation
import Foundation

/// Service for frame-accurate splitting of a single video into two files.
///
/// Unlike a passthrough (stream-copy) split — which can only cut on keyframe
/// boundaries — this re-encodes each half from the exact split frame, so the
/// cut is frame-accurate. It deliberately does **not** use the rendering
/// compositor or any effects pipeline; it is just two trimmed
/// `AVAssetExportSession` re-encodes, which keeps it fast and predictable.
///
/// The two halves are exported sequentially so only one decoder/encoder is
/// active at a time, and every export is guarded by two watchdogs: an inner
/// stall bound (``defaultStallTimeout`` — no forward progress for N seconds) and
/// an outer hard bound (``defaultExportTimeout``). Either one force-cancels the
/// session and fails with a diagnostic context describing *why* it stalled
/// (which half, last progress, segment/total durations, preset, audio). The job
/// therefore always terminates — success, failure, cancellation, stall or
/// timeout — and never leaves the method-channel result pending forever.
///
/// Note on stalls: a genuine hang here is almost always contention for the
/// shared VideoToolbox encode/decode session pool — the split runs on its own
/// `SplitVideoQueue` while speed renders run concurrently on `RenderVideoQueue`,
/// with no global cap on live `AVAssetExportSession`s. An exhausted pool leaves
/// a session at `progress == 0` indefinitely, which the stall bound now catches.
class SplitVideo {
  static let queue = DispatchQueue(label: "SplitVideoQueue")

  /// Default hard upper bound: the outer safety net. A single half may export
  /// this long before it is force-cancelled, even while still reporting
  /// progress. Overridable per-call via ``SplitVideoModel.exportTimeout``.
  static let defaultExportTimeout: TimeInterval = 120

  /// Default stall bound: if a half makes no forward progress for this long it
  /// is treated as stalled and force-cancelled. Overridable per-call via
  /// ``SplitVideoModel.stallTimeout``.
  static let defaultStallTimeout: TimeInterval = 12

  /// Starts an asynchronous frame-accurate split job.
  ///
  /// Writes `0 → splitUs` to `startOutputPath` and `splitUs → end` to
  /// `endOutputPath`, then reports the two paths via `onComplete`.
  @discardableResult
  static func split(
    inputPath: String,
    splitUs: Int64,
    startOutputPath: String,
    endOutputPath: String,
    outputFormat: String,
    bitrate: Int?,
    enableAudio: Bool,
    exportTimeout: TimeInterval = defaultExportTimeout,
    stallTimeout: TimeInterval = defaultStallTimeout,
    onProgress: @escaping (Double) -> Void,
    onComplete: @escaping ([String]) -> Void,
    onError: @escaping (Error) -> Void
  ) -> RenderJobHandle {
    let handle = RenderJobHandle()
    queue.async {
      let task = Task {
        do {
          guard FileManager.default.fileExists(atPath: inputPath) else {
            throw NSError(
              domain: "SplitVideo", code: 404,
              userInfo: [NSLocalizedDescriptionKey: "Input file not found: \(inputPath)"])
          }

          let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
          let duration = try await loadDuration(of: asset)
          let splitTime = CMTime(value: splitUs, timescale: 1_000_000)

          guard splitTime > .zero, splitTime < duration else {
            throw NSError(
              domain: "SplitVideo", code: 1,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Split position \(splitUs)us is outside the video duration"
              ])
          }

          let preset = applyBitrate(requestedBitrate: bitrate)
          let fileType = mapFormatToMimeType(format: outputFormat)

          // Source for export: the original asset keeps audio + orientation;
          // for a silent split we re-wrap into a video-only composition.
          let exportAsset: AVAsset =
            enableAudio ? asset : try await videoOnlyAsset(from: asset, duration: duration)

          PluginLog.print(
            "✂️ Splitting at \(String(format: "%.3f", CMTimeGetSeconds(splitTime)))s "
              + "(\(outputFormat), preset \(preset), audio: \(enableAudio))")

          let totalSeconds = CMTimeGetSeconds(duration)
          let splitSeconds = CMTimeGetSeconds(splitTime)
          let endDuration = CMTimeSubtract(duration, splitTime)

          // First half: 0 → split.
          try await exportSegment(
            asset: exportAsset,
            timeRange: CMTimeRange(start: .zero, duration: splitTime),
            outputPath: startOutputPath,
            fileType: fileType,
            preset: preset,
            diagnostics: SplitExportDiagnostics(
              half: .start, segmentSeconds: splitSeconds, splitSeconds: splitSeconds,
              totalSeconds: totalSeconds, preset: preset, enableAudio: enableAudio),
            exportTimeout: exportTimeout,
            stallTimeout: stallTimeout,
            handle: handle,
            onProgress: { onProgress($0 * 0.5) })

          try Task.checkCancellation()

          // Second half: split → end.
          try await exportSegment(
            asset: exportAsset,
            timeRange: CMTimeRange(start: splitTime, duration: endDuration),
            outputPath: endOutputPath,
            fileType: fileType,
            preset: preset,
            diagnostics: SplitExportDiagnostics(
              half: .end, segmentSeconds: CMTimeGetSeconds(endDuration),
              splitSeconds: splitSeconds, totalSeconds: totalSeconds, preset: preset,
              enableAudio: enableAudio),
            exportTimeout: exportTimeout,
            stallTimeout: stallTimeout,
            handle: handle,
            onProgress: { onProgress(0.5 + $0 * 0.5) })

          onComplete([startOutputPath, endOutputPath])
        } catch {
          onError(error)
        }
      }
      handle.attach(task: task)
    }
    return handle
  }

  // MARK: - Helpers

  /// Re-encodes a single time range of `asset` to `outputPath`, frame-accurate
  /// at the range start, guarded by the stall and hard-timeout bounds.
  private static func exportSegment(
    asset: AVAsset,
    timeRange: CMTimeRange,
    outputPath: String,
    fileType: AVFileType,
    preset: String,
    diagnostics: SplitExportDiagnostics,
    exportTimeout: TimeInterval,
    stallTimeout: TimeInterval,
    handle: RenderJobHandle,
    onProgress: @escaping (Double) -> Void
  ) async throws {
    let outputURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // AVAssetExportSession refuses to overwrite an existing file.
    try? FileManager.default.removeItem(at: outputURL)

    guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
      throw NSError(
        domain: "SplitVideo", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Export session creation failed"])
    }

    export.outputURL = outputURL
    export.outputFileType = fileType
    // A re-encoding preset honours `timeRange` sample-accurately (decodes from
    // the preceding keyframe and re-encodes from the exact start), which is what
    // makes the cut frame-accurate. Passthrough would snap to a keyframe.
    export.timeRange = timeRange
    export.shouldOptimizeForNetworkUse = true

    handle.attach(export: export)

    // Serialize against other encodes (split halves + concurrent renders) so
    // they don't starve each other on the hardware encoder. The wait is outside
    // the watchdog below, so queueing never counts as a stall.
    try await withExportSlot {
      try await runExportWithTimeout(
        export, diagnostics: diagnostics, exportTimeout: exportTimeout,
        stallTimeout: stallTimeout, onProgress: onProgress)
    }
  }

  /// Runs the export guarded by the shared ``ExportWatchdog`` (inner stall bound
  /// + outer hard bound). If a bound fires the session is force-cancelled and a
  /// diagnostic error is thrown; otherwise the monitor is torn down when the
  /// export finishes.
  private static func runExportWithTimeout(
    _ export: AVAssetExportSession,
    diagnostics: SplitExportDiagnostics,
    exportTimeout: TimeInterval,
    stallTimeout: TimeInterval,
    onProgress: @escaping (Double) -> Void
  ) async throws {
    try await ExportWatchdog.run(
      diagnostics: diagnostics,
      exportTimeout: exportTimeout,
      stallTimeout: stallTimeout,
      onProgress: onProgress,
      cancel: { export.cancelExport() },
      body: { progress in try await runExport(export, onProgress: progress) })
  }

  /// Drives the export to completion, reporting fractional progress.
  private static func runExport(
    _ export: AVAssetExportSession,
    onProgress: @escaping (Double) -> Void
  ) async throws {
    let updateInterval: TimeInterval = 0.2
    if #available(iOS 18.0, macOS 15.0, *) {
      let progressTask = Task {
        for try await state in export.states(updateInterval: updateInterval) {
          if case .exporting(let progress) = state {
            onProgress(progress.fractionCompleted)
          }
        }
      }
      try await export.export(to: export.outputURL!, as: export.outputFileType!)
      try await progressTask.value
    } else {
      let intervalNs = UInt64(updateInterval * 1_000_000_000)
      export.exportAsynchronously {}
      while export.status == .waiting || export.status == .exporting {
        if export.status == .exporting {
          onProgress(Double(min(max(export.progress, 0), 1.0)))
        }
        try await Task.sleep(nanoseconds: intervalNs)
      }
      guard export.status == .completed else {
        if export.status == .cancelled {
          throw CancellationError()
        }
        throw export.error
          ?? NSError(
            domain: "SplitVideo", code: 4,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Export failed with status \(export.status.rawValue)"
            ])
      }
    }
  }

  /// Builds a video-only composition (dropping audio) while preserving the
  /// source orientation, used for silent splits.
  private static func videoOnlyAsset(from asset: AVAsset, duration: CMTime) async throws
    -> AVAsset
  {
    let composition = AVMutableComposition()
    let videoTrack = try await loadVideoTrack(from: asset)
    guard
      let compTrack = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      throw NSError(
        domain: "SplitVideo", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Failed to create video track"])
    }
    try compTrack.insertTimeRange(
      CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)

    if #available(iOS 15.0, macOS 13.0, *) {
      compTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
    } else {
      compTrack.preferredTransform = videoTrack.preferredTransform
    }
    return composition
  }

  private static func loadDuration(of asset: AVAsset) async throws -> CMTime {
    if #available(iOS 15.0, macOS 13.0, *) {
      return try await asset.load(.duration)
    }
    return asset.duration
  }

  private static func loadVideoTrack(from asset: AVAsset) async throws -> AVAssetTrack {
    if #available(iOS 15.0, macOS 13.0, *) {
      let tracks = try await asset.loadTracks(withMediaType: .video)
      guard let track = tracks.first else {
        throw NSError(
          domain: "SplitVideo", code: 5,
          userInfo: [NSLocalizedDescriptionKey: "No video track found"])
      }
      return track
    } else {
      guard let track = asset.tracks(withMediaType: .video).first else {
        throw NSError(
          domain: "SplitVideo", code: 5,
          userInfo: [NSLocalizedDescriptionKey: "No video track found"])
      }
      return track
    }
  }
}

/// Immutable context for one exported half, used to enrich a stall/timeout
/// failure with actionable diagnostics. The bracketed suffix is intentionally
/// identical in structure to the Android side (`preset` here vs `mime` there).
struct SplitExportDiagnostics: ExportDiagnostics {
  enum Half: String { case start, end }

  let half: Half
  /// Duration of *this* segment in seconds.
  let segmentSeconds: Double
  /// Absolute split position in seconds.
  let splitSeconds: Double
  /// Total source duration in seconds.
  let totalSeconds: Double
  let preset: String
  let enableAudio: Bool

  /// e.g. `[half=end progress=0.00 segment=0.52s split=0.53s total=1.05s
  /// preset=AVAssetExportPresetHighestQuality audio=false]`
  func context(progress: Double) -> String {
    String(
      format:
        "[half=%@ progress=%.2f segment=%.2fs split=%.2fs total=%.2fs preset=%@ audio=%@]",
      half.rawValue, progress, segmentSeconds, splitSeconds, totalSeconds, preset,
      enableAudio ? "true" : "false")
  }

  func timeoutMessage(seconds: Int, progress: Double) -> String {
    "Split export timed out after \(seconds)s \(context(progress: progress))"
  }

  func stallMessage(seconds: Int, progress: Double) -> String {
    "Split export stalled after \(seconds)s with no progress \(context(progress: progress))"
  }
}
