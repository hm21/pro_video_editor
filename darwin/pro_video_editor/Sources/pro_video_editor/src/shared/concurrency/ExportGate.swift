import Foundation

/// Process-wide gate that serializes hardware-encoder-heavy export jobs across
/// the split and render pipelines.
///
/// Concurrent `AVAssetExportSession` / `AVAssetWriter` encodes contend for the
/// device's limited VideoToolbox encode/decode pool. Measured on macOS, three
/// concurrent 4K re-encodes each took ~43s versus ~19s run alone — every job
/// more than doubled, and on a throttled phone one can sit at `progress == 0`
/// until the watchdog fires (the reported split "freeze"). Serializing the
/// encodes keeps each at its solo latency with steady progress.
///
/// Only genuine *encode* paths acquire a slot; passthrough/stream-copy exports
/// (no encoder) run ungated. The gate wait happens **before** a job's
/// stall/timeout watchdog starts, so queueing never counts as a stall.
actor ExportGate {
  /// Shared gate. Limit 1 = one hardware encode at a time (the safe default;
  /// the split already assumed a single active encoder).
  static let shared = ExportGate(limit: 1)

  private let limit: Int
  private var available: Int
  private var waiters: [(id: UUID, cont: CheckedContinuation<Void, Error>)] = []

  init(limit: Int) {
    self.limit = max(1, limit)
    self.available = self.limit
  }

  /// Acquires a slot, suspending FIFO until one is free. Cancellation-safe: a
  /// waiter cancelled while queued removes itself and throws `CancellationError`
  /// (so the caller never runs its body and must not release).
  func acquire() async throws {
    if available > 0 {
      available -= 1
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { cont in
        waiters.append((id, cont))
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  /// Releases a slot: hands it directly to the next waiter (FIFO) or returns it
  /// to the pool.
  func release() {
    if !waiters.isEmpty {
      let waiter = waiters.removeFirst()
      waiter.cont.resume(returning: ())
    } else {
      available = min(available + 1, limit)
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.cont.resume(throwing: CancellationError())
  }
}

/// Runs [body] holding a single [ExportGate] slot, releasing it on success,
/// throw or cancellation. If the slot cannot be acquired (task cancelled while
/// queued) the error propagates and [body] never runs.
func withExportSlot<T>(_ body: () async throws -> T) async throws -> T {
  try await ExportGate.shared.acquire()
  do {
    let result = try await body()
    await ExportGate.shared.release()
    return result
  } catch {
    await ExportGate.shared.release()
    throw error
  }
}
