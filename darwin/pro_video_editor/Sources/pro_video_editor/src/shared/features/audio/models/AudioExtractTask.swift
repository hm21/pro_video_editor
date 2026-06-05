import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// AudioExtractTask - Manages lifecycle and state of an audio extraction operation.
///
/// This class tracks an active audio extraction job, handles cancellation,
/// and ensures thread-safe result delivery to Flutter.
///
/// Key responsibilities:
/// - Stores Flutter result callback
/// - Links to cancellable extraction job handle
/// - Provides thread-safe cancellation via NSLock
/// - Prevents duplicate result delivery
final class AudioExtractTask {
  let result: FlutterResult
  private var handle: AudioExtractJobHandle?
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

  func attachHandle(_ handle: @escaping AudioExtractJobHandle) {
    lock.lock()
    let alreadyCanceled = _isCanceled
    self.handle = handle
    lock.unlock()
    if alreadyCanceled {
      handle()
    }
  }

  func cancel() {
    lock.lock()
    _isCanceled = true
    let currentHandle = handle
    lock.unlock()
    currentHandle?()
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

/// Type alias for a function that cancels an audio extraction operation
typealias AudioExtractJobHandle = () -> Void