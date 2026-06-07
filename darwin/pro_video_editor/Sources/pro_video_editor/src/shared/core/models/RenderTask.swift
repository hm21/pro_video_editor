import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// RenderTask - Manages lifecycle and state of a single render operation.
///
/// This class tracks an active render job, handles cancellation,
/// and ensures thread-safe result delivery to Flutter.
///
/// Key responsibilities:
/// - Stores Flutter result callback
/// - Links to cancellable render job handle
/// - Provides thread-safe cancellation via NSLock
/// - Prevents duplicate result delivery
final class RenderTask {
  let result: FlutterResult
  private var handle: RenderJobHandle?
  private let lock = NSLock()
  private var _isCanceled: Bool
  private var resultConsumed: Bool

  init(result: @escaping FlutterResult) {
    self.result = result
    self._isCanceled = false
    self.resultConsumed = false
  }

  var isCanceled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _isCanceled
  }

  func attachHandle(_ handle: RenderJobHandle) {
    lock.lock()
    let alreadyCanceled = _isCanceled
    self.handle = handle
    lock.unlock()
    if alreadyCanceled {
      handle.cancel()
    }
  }

  func cancel() {
    lock.lock()
    _isCanceled = true
    let currentHandle = handle
    lock.unlock()
    currentHandle?.cancel()
  }

  func sendSuccess(_ payload: Any?) {
    takeResultHandler()?(payload)
  }

  func sendError(_ error: FlutterError) {
    takeResultHandler()?(error)
  }

  private func takeResultHandler() -> FlutterResult? {
    lock.lock()
    defer { lock.unlock() }
    if resultConsumed {
      return nil
    }
    resultConsumed = true
    return result
  }
}
