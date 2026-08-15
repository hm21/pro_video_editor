import AVFoundation
import Foundation

/// Guards the one-shot start of an ``AVAssetExportSession``.
///
/// `export(to:as:)` assigns `outputURL`/`outputFileType` before it starts, and
/// AVFoundation answers such an assignment on a session that already left
/// `.unknown` with an **Objective-C** `NSInternalInconsistencyException`
/// ("Cannot alter output URL attribute on an AVAssetExportSession after an
/// export has started"). Swift cannot catch that from an async context, so it
/// terminates the host app — the only defence is to never make the call.
///
/// The window this closes was not theoretical: an encode waits for an
/// ``ExportGate`` slot before it starts, and a cancel arriving during that wait
/// reached `cancelExport()` on a session that had never run. `.cancelled`
/// counts as "started", so the queued job crashed the moment the gate let it
/// through — a render opened and dismissed within a few seconds was enough.
///
/// Two things close it, and both are needed:
/// - ``RenderJobHandle`` only force-cancels a session whose start was claimed
///   here and that has actually left `.unknown`; an unstarted session is left
///   alone, because it has nothing to stop.
/// - ``claimStart(_:handle:label:)`` re-reads `status` immediately before the
///   call, so any *other* route into an already-started session surfaces as a
///   Swift error instead of a crash.
enum ExportSessionGuard {
  /// Domain of the errors thrown here, so callers can tell a refused start
  /// apart from an AVFoundation export failure.
  static let errorDomain = "ExportSessionGuard"

  /// Claims the right to start `export`, throwing when it must not be started.
  ///
  /// Throws `CancellationError` when the job was cancelled — either before the
  /// start (`handle`) or after (`status == .cancelled`); a cancelled export is
  /// a normal outcome, not a failure. Any other non-`.unknown` status means the
  /// session already ran, which is a programming error and is reported as one.
  ///
  /// Call this immediately before the start, with nothing suspending in
  /// between: it is a claim, not a reservation.
  static func claimStart(
    _ export: AVAssetExportSession,
    handle: RenderJobHandle? = nil,
    label: String
  ) throws {
    try Task.checkCancellation()
    guard handle?.beginExport() ?? true else { throw CancellationError() }

    switch export.status {
    case .unknown:
      return
    case .cancelled:
      throw CancellationError()
    default:
      let message =
        "\(label): export session already started (status \(export.status.rawValue))"
      PluginLog.print("⚠️ \(message)")
      throw NSError(
        domain: errorDomain, code: 1,
        userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  /// ``claimStart(_:handle:label:)`` followed by the start itself, for the call
  /// sites that need nothing in between. `url` and `fileType` default to what
  /// is already configured on the session.
  @available(iOS 18.0, macOS 15.0, *)
  static func start(
    _ export: AVAssetExportSession,
    to url: URL? = nil,
    as fileType: AVFileType? = nil,
    handle: RenderJobHandle? = nil,
    label: String
  ) async throws {
    guard let outputURL = url ?? export.outputURL,
      let outputFileType = fileType ?? export.outputFileType
    else {
      throw NSError(
        domain: errorDomain, code: 2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "\(label): export session has no output URL or file type"
        ])
    }

    try claimStart(export, handle: handle, label: label)
    try await export.export(to: outputURL, as: outputFileType)
  }
}
