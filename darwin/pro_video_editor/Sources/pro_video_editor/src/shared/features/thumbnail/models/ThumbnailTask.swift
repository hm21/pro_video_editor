import Foundation

/// Handle for cancelling an active streaming thumbnail job.
struct ThumbnailJobHandle {
  let cancel: () -> Void
}

/// Task wrapper for a streaming thumbnail job.
///
/// Tracks the job state and provides cancellation. A cancel that arrives
/// before the job handle is attached is remembered, so the handle is cancelled
/// the moment it lands.
class ThumbnailTask {
  private var handle: ThumbnailJobHandle?
  private(set) var isCanceled: Bool = false

  /// Attaches the running job; cancels it right away if `cancel()` already ran.
  func attachHandle(_ handle: ThumbnailJobHandle) {
    self.handle = handle
    if isCanceled {
      handle.cancel()
    }
  }

  /// Marks this task as canceled and invokes the job's cancel handler.
  func cancel() {
    isCanceled = true
    handle?.cancel()
  }
}
