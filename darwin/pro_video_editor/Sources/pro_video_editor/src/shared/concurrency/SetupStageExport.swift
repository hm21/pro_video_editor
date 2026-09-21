import AVFoundation
import Foundation

/// Runs one of the render pipeline's setup-stage encodes — the HDR
/// pre-transcode and the overlap-transition pre-render — under the same
/// ``ExportGate`` slot and ``ExportWatchdog`` as the main encode.
///
/// Both stages are genuine hardware encodes: the transcoder re-encodes a whole
/// clip to H.264 8-bit, the transition renderer encodes one blended clip per
/// seam. They used to run outside both the gate and the watchdog, so they
/// contended with every other encode in the process — and with each other,
/// one pre-transcode per clip per concurrent render — which is exactly the
/// starvation the gate exists to prevent. A session that then sat at 0 %
/// never returned: nothing force-cancelled it, the job's own watchdog had not
/// started yet, and the caller's `onComplete`/`onError` never fired (#201).
///
/// The slot is acquired per encode, not once around a whole stage, so a job
/// with N seams does not hold the gate through N blends while a split waits.
/// Only the stall bound applies (no hard bound): a transcode re-encodes the
/// whole clip, whose length is unbounded, so a slow-but-progressing one must
/// never be killed.
enum SetupStageExport {
  /// No-progress bound for a setup-stage encode. The same as the main
  /// encode's (`RenderVideo.renderStallTimeout`): the same starved encoder
  /// produces the same `progress == 0` stall in every stage. A `var` so a test
  /// can tighten it.
  static var stallTimeout: TimeInterval = RenderVideo.renderStallTimeout

  /// Drives `export` to completion inside a gate slot, bounded by the stall
  /// watchdog.
  ///
  /// Throws `CancellationError` when the job was cancelled — while still
  /// queued for the slot, or during the encode — and the watchdog's own
  /// `NSError` (``isStall(_:)``) when the encode stopped making progress. Any
  /// other error is the export's own failure.
  static func run(
    _ export: AVAssetExportSession,
    to url: URL? = nil,
    as fileType: AVFileType? = nil,
    diagnostics: ExportDiagnostics,
    label: String,
    failureDomain: String
  ) async throws {
    // The gate wait sits outside the watchdog, so queueing never counts as a
    // stall.
    try await withExportSlot {
      try await ExportWatchdog.run(
        diagnostics: diagnostics,
        exportTimeout: 0,
        stallTimeout: stallTimeout,
        // Neither stage reports progress to the caller; the feed only has to
        // reach the monitor, which reads it through its own box.
        onProgress: { _ in },
        // A stall detected while the session is still queued must not cancel
        // it — see `ExportSessionGuard.forceCancel`.
        cancel: { ExportSessionGuard.forceCancel(export) },
        body: { progress in
          try await ExportSessionDriver.run(
            export, to: url, as: fileType, label: label,
            failureDomain: failureDomain, onProgress: progress)
        })
    }
  }

  /// Whether `error` is the watchdog ending a stalled encode.
  ///
  /// A stall is a starved or wedged encoder, not a property of the clip: the
  /// stages must not fall back — the transcoder onto the HDR source, the
  /// transition onto a hard cut — but fail the job with this error, so the
  /// caller retries once the encoder is free instead of caching a wrong
  /// result.
  static func isStall(_ error: Error) -> Bool {
    (error as NSError).domain == ExportWatchdog.errorDomain
  }
}
