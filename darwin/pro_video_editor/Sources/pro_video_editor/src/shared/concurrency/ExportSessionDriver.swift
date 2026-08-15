import AVFoundation
import Foundation

/// Drives one ``AVAssetExportSession`` from start to finish: claims the start
/// through ``ExportSessionGuard``, reports fractional progress, and makes sure
/// a cancellation actually stops the encoder.
///
/// Every `async` export in the plugin runs through here — the render, both
/// split halves, the overlap-transition pre-render, the HDR pre-transcode and
/// the audio-merge container. They each used to carry their own copy of the
/// same ~40 lines, so a fix to the start/cancel dance had to be made (and kept
/// in sync) five times.
///
/// The one export outside it is ``ExtractAudio``, which is callback- and
/// timer-driven rather than `async` and so has no task to unwind; it stops its
/// own start on cancel and routes its cancel through
/// ``ExportSessionGuard/forceCancel(_:)`` like everything else.
///
/// Two rules it enforces that driving the session by hand does not:
/// - The progress observer is created only *after* the start is claimed. A
///   start refused by a cancel would otherwise leave a task streaming
///   `states()` — reporting progress for a job that already failed, and
///   holding on to the session, its composition and the custom compositor.
/// - Unwinding on cancellation force-cancels the session. On iOS 18/macOS 15+
///   `export(to:as:)` unwinds together with its task, but the legacy
///   `exportAsynchronously` path is fire-and-forget: nothing else would stop
///   that encoder, and it would keep writing after ``ExportGate`` handed its
///   slot to the next job.
enum ExportSessionDriver {
  /// Cadence of the progress reports (both the async `states()` sequence and
  /// the legacy poll loop).
  private static let progressInterval: TimeInterval = 0.2

  /// Runs `export` to completion.
  ///
  /// Throws `CancellationError` when the job was cancelled — before the start
  /// (refused by the guard) or during it. `url`/`fileType` default to whatever
  /// the session already carries.
  ///
  /// - Parameters:
  ///   - handle: job handle whose cancel refuses the start, if there is one.
  ///   - label: name used in the guard's diagnostics (e.g. `"Render"`).
  ///   - failureDomain: `NSError` domain for an export that ends in neither
  ///     `.completed` nor `.cancelled` without reporting an error of its own.
  ///   - onProgress: fractional progress, or nil to skip progress observation
  ///     entirely (no observer task is created then).
  static func run(
    _ export: AVAssetExportSession,
    to url: URL? = nil,
    as fileType: AVFileType? = nil,
    handle: RenderJobHandle? = nil,
    label: String,
    failureDomain: String,
    onProgress: ((Double) -> Void)? = nil
  ) async throws {
    guard let outputURL = url ?? export.outputURL,
      let outputFileType = fileType ?? export.outputFileType
    else {
      throw NSError(
        domain: ExportSessionGuard.errorDomain, code: 2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "\(label): export session has no output URL or file type"
        ])
    }

    if #available(iOS 18.0, macOS 15.0, *) {
      try await runAsync(
        export, to: outputURL, as: outputFileType, handle: handle, label: label,
        onProgress: onProgress)
    } else {
      try await runPolled(
        export, to: outputURL, as: outputFileType, handle: handle, label: label,
        failureDomain: failureDomain, onProgress: onProgress)
    }
  }

  /// iOS 18 / macOS 15+: `export(to:as:)` plus the `states()` progress stream.
  @available(iOS 18.0, macOS 15.0, *)
  private static func runAsync(
    _ export: AVAssetExportSession,
    to url: URL,
    as fileType: AVFileType,
    handle: RenderJobHandle?,
    label: String,
    onProgress: ((Double) -> Void)?
  ) async throws {
    // Claimed before the observer exists, so a refused start leaves nothing
    // behind. Creating a `Task` does not suspend, so the claim still sits
    // immediately before the start, as `claimStart` requires.
    try ExportSessionGuard.claimStart(export, handle: handle, label: label)

    let progressTask = onProgress.map { report in
      Task {
        for try await state in export.states(updateInterval: progressInterval) {
          if case .exporting(let progress) = state {
            report(progress.fractionCompleted)
          }
        }
      }
    }

    do {
      try await export.export(to: url, as: fileType)
    } catch {
      progressTask?.cancel()
      // Awaited, not just cancelled: the observer holds on to the session, its
      // composition and the custom compositor, and the caller releases its
      // ``ExportGate`` slot the moment this throws — the next job would build
      // its own composition alongside this one.
      _ = try? await progressTask?.value
      // A watchdog that fired while the session was still `.unknown` left it
      // alone on purpose (see `ExportSessionGuard.forceCancel`); the deferred
      // force-cancel lands here, once the start is through.
      if Task.isCancelled || error is CancellationError {
        ExportSessionGuard.forceCancel(export)
      }
      throw error
    }

    try await progressTask?.value
  }

  /// Pre-iOS 18 / pre-macOS 15: `exportAsynchronously` plus a polling loop.
  private static func runPolled(
    _ export: AVAssetExportSession,
    to url: URL,
    as fileType: AVFileType,
    handle: RenderJobHandle?,
    label: String,
    failureDomain: String,
    onProgress: ((Double) -> Void)?
  ) async throws {
    try ExportSessionGuard.claimStart(export, handle: handle, label: label)
    // Safe here and nowhere else: the claim above just proved the session is
    // still `.unknown`, and it is exactly this assignment that AVFoundation
    // answers with an uncatchable exception once an export has started.
    export.outputURL = url
    export.outputFileType = fileType
    export.exportAsynchronously {}

    do {
      let intervalNs = UInt64(progressInterval * 1_000_000_000)
      // Driven by the states an export cannot leave, not by the ones it passes
      // through: `exportAsynchronously` publishes its status change on its own
      // queue, so the first read here can still see `.unknown`. Waiting for
      // `.waiting`/`.exporting` instead would exit the loop right then and
      // report a perfectly healthy export as "failed with status 0" — while
      // the encoder it never stopped kept running past the gate slot.
      while !isTerminal(export.status) {
        if export.status == .exporting {
          onProgress?(Double(min(max(export.progress, 0), 1.0)))
        }
        try await Task.sleep(nanoseconds: intervalNs)
      }
    } catch {
      // `exportAsynchronously` is fire-and-forget: this loop is the only thing
      // tied to the surrounding task, so without cancelling here the encoder
      // would keep running unsupervised — past the gate slot it no longer holds
      // and past the job that started it.
      ExportSessionGuard.forceCancel(export)
      throw error
    }

    guard export.status == .completed else {
      // A cancelled export is the caller's own doing, not a failure.
      if export.status == .cancelled { throw CancellationError() }
      throw export.error
        ?? NSError(
          domain: failureDomain, code: 4,
          userInfo: [
            NSLocalizedDescriptionKey:
              "\(label): export failed with status \(export.status.rawValue)"
          ])
    }
  }

  /// Whether `status` is one an export session never leaves on its own.
  private static func isTerminal(_ status: AVAssetExportSession.Status) -> Bool {
    switch status {
    case .completed, .failed, .cancelled: return true
    default: return false
    }
  }
}
