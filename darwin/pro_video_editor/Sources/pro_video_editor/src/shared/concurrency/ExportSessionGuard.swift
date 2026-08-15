import AVFoundation
import Foundation

/// Guards the one-shot start of an ``AVAssetExportSession``.
///
/// `export(to:as:)` assigns `outputURL` and `outputFileType` before it starts,
/// and AVFoundation answers such an assignment on a session that has already
/// left `.unknown` with an **Objective-C** `NSInternalInconsistencyException`
/// ("Cannot alter output URL attribute on an AVAssetExportSession after an
/// export has started"). Swift cannot catch an ObjC exception from an async
/// context, so it terminates the host app — the only defence is to never make
/// the call.
///
/// The window this closes was not theoretical. An encode waits for an
/// ``ExportGate`` slot before it runs, and a cancel arriving during that wait
/// reached `cancelExport()` on a session that had never started. `.cancelled`
/// counts as "started", so the job crashed the moment the gate let it through —
/// a render opened and dismissed within a few seconds was enough.
///
/// Two changes close it, and both are needed:
/// - ``RenderJobHandle`` no longer force-cancels a session that has not left
///   `.unknown`; an unstarted session has nothing to stop, and cancelling it is
///   precisely what arms the crash.
/// - ``claimStart(_:handle:label:)`` re-reads `status` immediately before the
///   call, so any *other* route into an already-started session surfaces as a
///   Swift error rather than as a process kill.
enum ExportSessionGuard {
  /// Domain of the errors thrown here, so a refused start can be told apart
  /// from an AVFoundation export failure.
  static let errorDomain = "ExportSessionGuard"

  /// Claims the right to start `export`, throwing when it must not be started.
  ///
  /// Throws `CancellationError` when the job was cancelled — either before the
  /// start was claimed (via `handle`) or after (`status == .cancelled`). A
  /// cancelled export is a normal outcome, not a failure. Any other
  /// non-`.unknown` status means the session already ran, which is a
  /// programming error and is reported as one.
  ///
  /// Call this immediately before the start with nothing suspending in
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

  /// ``claimStart(_:handle:label:)`` immediately followed by the start itself,
  /// for the call sites that need nothing in between. `url` and `fileType`
  /// default to what is already configured on the session.
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

  /// Whether `export` has left `.unknown`, i.e. whether `cancelExport()` has
  /// something to stop.
  static func hasStarted(_ export: AVAssetExportSession) -> Bool {
    export.status != .unknown
  }

  /// Force-cancels `export`, but only once it has actually started.
  ///
  /// `cancelExport()` on an unstarted session moves it to `.cancelled`, which
  /// is exactly what arms the crash this file exists to prevent. Every
  /// force-cancel path — the job handle and the watchdog's `cancel` hook —
  /// goes through here so none of them can re-open that window.
  static func forceCancel(_ export: AVAssetExportSession) {
    guard hasStarted(export) else { return }
    export.cancelExport()
  }
}
