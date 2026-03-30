import FlutterMacOS
import Foundation

/// Handle for cancelling an active waveform generation job.
struct WaveformJobHandle {
    let cancel: () -> Void
}

/// Task wrapper for managing waveform generation jobs.
///
/// Tracks the job state and provides thread-safe cancellation.
class WaveformTask {
    private var handle: WaveformJobHandle?
    private let flutterResult: FlutterResult
    private(set) var isCanceled: Bool = false

    init(result: @escaping FlutterResult) {
        self.flutterResult = result
    }

    /// Attaches the job handle for cancellation support.
    func attachHandle(_ handle: WaveformJobHandle) {
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

    /// Sends a successful result back to Flutter.
    func sendSuccess(_ data: [String: Any?]) {
        if !isCanceled {
            flutterResult(data)
        }
    }

    /// Sends an error result back to Flutter.
    func sendError(_ error: FlutterError) {
        flutterResult(error)
    }
}
