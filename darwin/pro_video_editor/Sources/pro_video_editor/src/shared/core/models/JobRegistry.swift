import Foundation

/// The jobs of one kind the plugin is tracking, by id.
///
/// A cancel from Dart answers at once and frees the id, but the pipeline
/// behind the job is still unwinding — AVFoundation cancels an export session
/// asynchronously — and on its way out it may still remove the output it was
/// writing. A job started under that id in the meantime (a retry, at the same
/// path) would find its own output deleted from under it. So a job whose
/// predecessor is still unwinding is registered — the id is taken, its call
/// pending — but its pipeline starts only once the predecessor has reported
/// back.
///
/// That holds only as long as every pipeline reports its end after a cancel —
/// which each of them does, through the export session's completion or the
/// task's cancellation unwinding. One that stayed quiet would keep the id's
/// next start waiting for good.
///
/// Everything here runs on the main thread, like every other access to the
/// task maps.
final class JobRegistry<Job: ChannelTask> {
  /// Jobs that answer to `cancelTask`, by id.
  private var active: [String: Job] = [:]
  /// Cancelled jobs whose pipeline has yet to report, by the id they held.
  private var unwinding: [String: Job] = [:]
  /// Pipeline starts held back behind an unwinding job, by id.
  private var pending: [String: () -> Void] = [:]

  /// Whether a job holds `id`.
  func isRunning(_ id: String) -> Bool {
    active[id] != nil
  }

  /// Registers `job` under `id` and runs `start` — now, or once the job
  /// cancelled under the same id has finished unwinding.
  func start(_ job: Job, id: String, _ start: @escaping () -> Void) {
    active[id] = job
    if unwinding[id] == nil {
      start()
    } else {
      pending[id] = start
    }
  }

  /// Cancels the job under `id` and frees the id, returning the job so the
  /// caller can answer it. A job that never started is simply dropped; one that
  /// did keeps the id's next start waiting until its pipeline reports.
  func cancel(_ id: String) -> Job? {
    guard let job = active.removeValue(forKey: id) else { return nil }
    job.cancel()
    if pending.removeValue(forKey: id) == nil {
      unwinding[id] = job
    }
    return job
  }

  /// Records that `job`'s pipeline has reported. Frees `id` when the job still
  /// held it; otherwise the job was cancelled, and the start waiting behind it,
  /// if any, runs now.
  func settle(_ job: Job, id: String) {
    if active[id] === job {
      active.removeValue(forKey: id)
    } else if unwinding[id] === job {
      unwinding.removeValue(forKey: id)
      pending.removeValue(forKey: id)?()
    }
  }

  /// Cancels every job and forgets all of them; nothing waiting starts.
  func cancelAll() {
    active.values.forEach { $0.cancel() }
    active.removeAll()
    unwinding.removeAll()
    pending.removeAll()
  }
}
