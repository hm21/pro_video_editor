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
/// active at a time, and every export is guarded by a watchdog
/// (``exportTimeout``) that force-cancels a stalled session. The job therefore
/// always terminates — success, failure, cancellation or timeout — and never
/// leaves the method-channel result pending forever.
class SplitVideo {
  static let queue = DispatchQueue(label: "SplitVideoQueue")

  /// Maximum time a single half may export before it is force-cancelled and
  /// reported as a failure. Prevents a stalled `AVAssetExportSession` from
  /// hanging the method-channel result indefinitely.
  static let exportTimeout: TimeInterval = 120

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

          // First half: 0 → split.
          try await exportSegment(
            asset: exportAsset,
            timeRange: CMTimeRange(start: .zero, duration: splitTime),
            outputPath: startOutputPath,
            fileType: fileType,
            preset: preset,
            handle: handle,
            onProgress: { onProgress($0 * 0.5) })

          try Task.checkCancellation()

          // Second half: split → end.
          try await exportSegment(
            asset: exportAsset,
            timeRange: CMTimeRange(
              start: splitTime, duration: CMTimeSubtract(duration, splitTime)),
            outputPath: endOutputPath,
            fileType: fileType,
            preset: preset,
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
  /// at the range start, guarded by ``exportTimeout``.
  private static func exportSegment(
    asset: AVAsset,
    timeRange: CMTimeRange,
    outputPath: String,
    fileType: AVFileType,
    preset: String,
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

    try await runExportWithTimeout(export, onProgress: onProgress)
  }

  /// Runs the export and races it against the watchdog timeout. On timeout the
  /// session is cancelled and a timeout error is thrown.
  private static func runExportWithTimeout(
    _ export: AVAssetExportSession,
    onProgress: @escaping (Double) -> Void
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await runExport(export, onProgress: onProgress)
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(exportTimeout * 1_000_000_000))
        export.cancelExport()
        throw NSError(
          domain: "SplitVideo", code: 408,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Split export timed out after \(Int(exportTimeout))s"
          ])
      }
      // Surface whichever finishes first (success, error or timeout), then
      // cancel the loser.
      try await group.next()
      group.cancelAll()
    }
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
