import Foundation

/// Source of the diagnostic messages a guarded export emits when it stalls or
/// times out. Each pipeline provides its own context (``SplitExportDiagnostics``
/// for the split, ``RenderExportDiagnostics`` for the render).
protocol ExportDiagnostics {
  func stallMessage(seconds: Int, progress: Double) -> String
  func timeoutMessage(seconds: Int, progress: Double) -> String
}

/// Thread-safe, monotonically-increasing progress holder shared between the
/// export task (writer) and the stall monitor (reader).
final class ProgressBox {
  private let lock = NSLock()
  private var stored: Double = 0

  /// Records `value` if it exceeds the current maximum. Export progress only
  /// moves forward, so clamping to the max ignores any spurious lower reports.
  func update(_ value: Double) {
    lock.lock()
    if value > stored { stored = value }
    lock.unlock()
  }

  var value: Double {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

/// Races a running export against a stall / hard-timeout monitor.
///
/// This matters now that both the split and render pipelines hold a single
/// process-wide ``ExportGate`` slot while encoding: a body that neither returns
/// nor throws would never `release()` the slot and would deadlock *every* later
/// export. The monitor force-cancels a stalled session, which unwinds the body
/// and frees the slot, so a wedged encoder can only ever hang its own job.
///
/// Two bounds are enforced:
/// - inner **stall** bound: no forward progress for `stallTimeout` (the
///   "stuck at 0%" hardware-pool-exhaustion case). Past the finalize watermark
///   it is *relaxed* to `finalizeGrace` — not disabled — because the moov-atom
///   rewrite (`shouldOptimizeForNetworkUse`) is progress-silent healthy I/O, yet
///   a *wedged* finalize must still terminate and release the gate.
/// - outer **hard** bound: an absolute wall-clock cap, even while still
///   reporting progress. Skipped when `exportTimeout <= 0` (the render pipeline
///   has no fixed upper bound on clip length, so it relies on the stall bound
///   alone).
///
/// Timing uses the monotonic uptime clock (immune to wall-clock/NTP steps),
/// matching the Android side's `SystemClock.uptimeMillis()`.
enum ExportWatchdog {
  /// Domain of the diagnostic stall/timeout errors thrown by the monitor,
  /// used by callers to tell a watchdog failure apart from other errors.
  static let errorDomain = "ExportWatchdog"

  private static let pollInterval: TimeInterval = 0.25

  /// Progress fraction past which the encode is effectively done and only the
  /// progress-silent container finalize (moov rewrite) remains. The stall bound
  /// is relaxed — not disabled — beyond it (see ``finalizeGrace``).
  private static let finalizeWatermark: Double = 0.99

  /// No-progress tolerance during the finalize tail (progress ≥
  /// ``finalizeWatermark``). Generous enough that a real moov rewrite of a large
  /// file completes, but still bounded so a *wedged* finalize releases the gate
  /// instead of hanging forever — without it, a render (which runs with no hard
  /// bound) that wedges past the watermark would deadlock every later export.
  private static let finalizeGrace: TimeInterval = 60

  /// Drives `body` (which reports progress through the callback it is handed)
  /// while the monitor enforces the stall and hard bounds. Whichever of
  /// body/monitor finishes first wins; the loser is then cancelled. If the
  /// monitor fires it calls `cancel` (force-cancel the underlying session) and
  /// throws a diagnostic error.
  static func run(
    diagnostics: ExportDiagnostics,
    exportTimeout: TimeInterval,
    stallTimeout: TimeInterval,
    onProgress: @escaping (Double) -> Void,
    cancel: @escaping () -> Void,
    body: @escaping (@escaping (Double) -> Void) async throws -> Void
  ) async throws {
    // The monitor reads progress through this box, fed by the same callbacks
    // that drive `onProgress`, so "stuck at X%" reflects the last real value.
    let progress = ProgressBox()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await body { value in
          progress.update(value)
          onProgress(value)
        }
      }
      group.addTask {
        try await monitor(
          progress: progress, diagnostics: diagnostics,
          exportTimeout: exportTimeout, stallTimeout: stallTimeout, cancel: cancel)
      }
      // Surface whichever finishes first (success, error, stall or timeout),
      // then cancel the loser. If `group.next()` throws (the monitor fired) the
      // group implicitly cancels and awaits the still-running body on scope exit.
      do {
        try await group.next()
        group.cancelAll()
      } catch {
        group.cancelAll()
        // The monitor force-cancels the session *before* it throws its
        // diagnostic error, so the body can surface its CancellationError
        // first — a race that would misreport a stall/timeout as a user
        // cancellation (likely with a fast export and a tight bound). Drain
        // the remaining child and let a fired watchdog override the
        // cancellation with its diagnostic error. A genuine user cancel
        // instead unwinds the still-sleeping monitor as a CancellationError,
        // which keeps the original error.
        if error is CancellationError {
          do {
            try await group.next()
          } catch let watchdogError as NSError
            where watchdogError.domain == errorDomain
          {
            throw watchdogError
          } catch {}
        }
        throw error
      }
    }
  }

  private static func monitor(
    progress: ProgressBox,
    diagnostics: ExportDiagnostics,
    exportTimeout: TimeInterval,
    stallTimeout: TimeInterval,
    cancel: @escaping () -> Void
  ) async throws {
    let start = DispatchTime.now()
    var lastProgress = progress.value
    var lastAdvance = start

    while true {
      // Sleep until the next poll, but never past an armed bound: a bound
      // tighter than the poll interval must still fire on time. A passthrough
      // split can finish in ~10ms, so a millisecond-scale bound that is only
      // checked at the first 250ms poll would lose the race against the export
      // and never fire. Real-world bounds (seconds) keep the 250ms cadence.
      var sleepSeconds = pollInterval
      if stallTimeout > 0 {
        let bound =
          progress.value >= finalizeWatermark ? max(stallTimeout, finalizeGrace) : stallTimeout
        sleepSeconds = min(sleepSeconds, max(0, bound - elapsed(since: lastAdvance)))
      }
      if exportTimeout > 0 {
        sleepSeconds = min(sleepSeconds, max(0, exportTimeout - elapsed(since: start)))
      }
      try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
      let current = progress.value
      if current > lastProgress {
        lastProgress = current
        lastAdvance = DispatchTime.now()
      }

      // Inner bound: no forward progress for `stallTimeout`. Past the finalize
      // watermark the bound is relaxed to `finalizeGrace` (the progress-silent
      // moov rewrite must not be misread as a stall) but never fully disabled,
      // so a wedged finalize still terminates and releases the gate.
      if stallTimeout > 0 {
        let bound =
          current >= finalizeWatermark ? max(stallTimeout, finalizeGrace) : stallTimeout
        if elapsed(since: lastAdvance) >= bound {
          let message = diagnostics.stallMessage(
            seconds: Int(bound.rounded()), progress: current)
          PluginLog.print("⏱️ \(message)")
          cancel()
          throw NSError(
            domain: errorDomain, code: 408,
            userInfo: [NSLocalizedDescriptionKey: message])
        }
      }

      // Outer bound: absolute wall-clock cap. Skipped when non-positive.
      if exportTimeout > 0, elapsed(since: start) >= exportTimeout {
        let message = diagnostics.timeoutMessage(
          seconds: Int(exportTimeout.rounded()), progress: current)
        PluginLog.print("⏱️ \(message)")
        cancel()
        throw NSError(
          domain: errorDomain, code: 408,
          userInfo: [NSLocalizedDescriptionKey: message])
      }
    }
  }

  /// Monotonic seconds elapsed since `mark` (uptime clock).
  private static func elapsed(since mark: DispatchTime) -> TimeInterval {
    Double(DispatchTime.now().uptimeNanoseconds &- mark.uptimeNanoseconds) / 1_000_000_000
  }
}
