import Foundation

#if os(iOS)
  import UIKit
#endif

/// Runs an export job so that leaving the app does not fail it.
///
/// iOS suspends an app a few seconds after it leaves the foreground, and an
/// export that was running then fails with `AVError.operationInterrupted` as
/// soon as the app returns. This keeps that from reaching the caller:
///
/// - Every attempt holds a background task, so the export keeps encoding while
///   the app is away, for as long as the system grants (about 30 seconds).
/// - When that time runs out, the attempt is stopped right away, so the
///   encoder and its buffers are released before the app is suspended rather
///   than frozen with it.
/// - An attempt that ends after the app left the foreground starts over from
///   scratch once the app is active, however long it was away. Its progress
///   starts over from zero.
/// - A job does not start in the background once the time left there is too
///   short to get anywhere; it starts when the app is active again.
///
/// macOS does not suspend apps, so there an attempt runs once, as before.
enum BackgroundSafeJob {
  /// Background time a job needs left to start in the background; with less,
  /// it waits until the app is active.
  static let minimumBackgroundTimeToStart: TimeInterval = 10

  /// Starts one run of a job under the handle it is given, and reports
  /// through one of the two closures, once.
  typealias Attempt<Output> = (
    _ attemptHandle: RenderJobHandle,
    _ complete: @escaping (Output) -> Void,
    _ fail: @escaping (Error) -> Void
  ) -> Void

  /// Runs `attempt` until it completes, fails while the app stayed in the
  /// foreground, or `handle` is cancelled, then reports through exactly one
  /// of `onComplete` and `onError`.
  ///
  /// - Parameters:
  ///   - label: name used in log lines (e.g. `"Render"`).
  ///   - handle: the job's handle. Cancelling it cancels the running attempt
  ///     or ends a wait for the app, with a `CancellationError`.
  ///   - environment: the app the job runs in; tests pass their own.
  ///   - attempt: one run of the job; see ``Attempt``.
  static func run<Output>(
    label: String,
    handle: RenderJobHandle,
    environment: AppEnvironment = .current,
    attempt: @escaping Attempt<Output>,
    onComplete: @escaping (Output) -> Void,
    onError: @escaping (Error) -> Void
  ) {
    let start = Task {
      do {
        try await environment.waitUntilWorkCanStart()
      } catch {
        onError(error)
        return
      }
      runAttempt(
        label: label, handle: handle, environment: environment, attempt: attempt,
        onComplete: onComplete, onError: onError)
    }
    handle.attach(task: start)
  }

  private static func runAttempt<Output>(
    label: String,
    handle: RenderJobHandle,
    environment: AppEnvironment,
    attempt: @escaping Attempt<Output>,
    onComplete: @escaping (Output) -> Void,
    onError: @escaping (Error) -> Void
  ) {
    // Its own handle, so the background time running out can stop this
    // attempt without cancelling the job.
    let attemptHandle = RenderJobHandle()
    handle.attach(child: attemptHandle)
    let activity = environment.beginActivity(label) {
      attemptHandle.cancel()
    }
    attempt(
      attemptHandle,
      { output in
        activity.end()
        onComplete(output)
      },
      { error in
        activity.end()
        let recovery = Task {
          guard !handle.isCanceled, await activity.leftForeground() else {
            onError(error)
            return
          }
          PluginLog.print(
            "⚠️ \(label) interrupted after the app left the foreground "
              + "(\(error.localizedDescription)); starting over once it is back")
          do {
            try await environment.waitUntilActive()
          } catch {
            onError(error)
            return
          }
          runAttempt(
            label: label, handle: handle, environment: environment, attempt: attempt,
            onComplete: onComplete, onError: onError)
        }
        // A cancel during the wait has to reach it: the attempt has finished,
        // so the handle would otherwise cancel nothing.
        handle.attach(task: recovery)
      })
  }
}

/// What ``BackgroundSafeJob`` needs from the app it runs in.
struct AppEnvironment {
  /// Starts one attempt's background task and its watch for the app leaving
  /// the foreground. `onExpired` runs, on the main thread, if the background
  /// time runs out before the attempt ends.
  let beginActivity: (_ label: String, _ onExpired: @escaping () -> Void) -> AppActivity

  /// Returns once a job may start: at once while the app is active or has at
  /// least ``BackgroundSafeJob/minimumBackgroundTimeToStart`` of background
  /// time left, otherwise once it is active again. Throws `CancellationError`
  /// when the waiting task is cancelled first.
  let waitUntilWorkCanStart: () async throws -> Void

  /// Returns once the app is active, at once when it already is. Throws
  /// `CancellationError` when the waiting task is cancelled first.
  let waitUntilActive: () async throws -> Void

  /// The app this process runs: UIKit's on iOS, a no-op on macOS.
  static var current: AppEnvironment {
    #if os(iOS)
      return AppEnvironment(
        beginActivity: { UIKitAppActivity(label: $0, onExpired: $1) },
        waitUntilWorkCanStart: {
          try await UIKitActiveWaiter(
            orBackgroundTimeLeft: BackgroundSafeJob.minimumBackgroundTimeToStart
          ).wait()
        },
        waitUntilActive: { try await UIKitActiveWaiter().wait() })
    #else
      return AppEnvironment(
        beginActivity: { _, _ in AlwaysForegroundActivity() },
        waitUntilWorkCanStart: {},
        waitUntilActive: {})
    #endif
  }
}

/// One attempt's background task and its record of the app leaving the
/// foreground.
protocol AppActivity: AnyObject {
  /// Whether the app has been out of the foreground at any point since the
  /// attempt began, the present moment included.
  func leftForeground() async -> Bool

  /// Ends the background task and stops watching. Safe to call more than once.
  func end()
}

/// An app that never leaves the foreground: macOS.
final class AlwaysForegroundActivity: AppActivity {
  func leftForeground() async -> Bool { false }
  func end() {}
}

#if os(iOS)
  /// An attempt's background task plus a watch on `willResignActive`.
  ///
  /// Resigning active is the earliest sign of the app being left, and also
  /// covers an interruption that never reaches the background (a call, Siri).
  /// `UIApplication`'s background-task calls are safe from any thread, so the
  /// task is begun on whichever queue starts the attempt.
  final class UIKitAppActivity: AppActivity, @unchecked Sendable {
    private let lock = NSLock()
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var released = false
    private var resigned = false
    private var observer: NSObjectProtocol?

    init(label: String, onExpired: @escaping () -> Void) {
      let observer = NotificationCenter.default.addObserver(
        forName: UIApplication.willResignActiveNotification, object: nil, queue: nil
      ) { [weak self] _ in
        self?.markResigned()
      }
      lock.lock()
      self.observer = observer
      lock.unlock()

      // The job may start while the app is already on its way out, after the
      // notification above was posted.
      DispatchQueue.main.async { [weak self] in
        if UIApplication.shared.applicationState != .active {
          self?.markResigned()
        }
      }

      let id = UIApplication.shared.beginBackgroundTask(
        withName: "pro_video_editor.\(label)"
      ) { [weak self] in
        PluginLog.print(
          "⚠️ \(label): background time ran out; the export starts over once the app is back")
        // Stopped before the task ends, while the app still runs: a suspended
        // encode would otherwise hold its buffers until the app returns.
        if self?.isRunning == true { onExpired() }
        self?.releaseBackgroundTask()
      }
      lock.lock()
      let releaseNow = released
      if !releaseNow { taskID = id }
      lock.unlock()
      // Expired or ended before the identifier was stored above.
      if releaseNow, id != .invalid {
        UIApplication.shared.endBackgroundTask(id)
      }
    }

    deinit {
      end()
    }

    func leftForeground() async -> Bool {
      if hasResigned { return true }
      // The failure can arrive before the main queue has delivered the
      // notification — on return the interrupted export fails during
      // `willEnterForeground`, while the app is still inactive.
      return await MainActor.run { UIApplication.shared.applicationState != .active }
    }

    func end() {
      lock.lock()
      let observer = self.observer
      self.observer = nil
      lock.unlock()
      if let observer {
        NotificationCenter.default.removeObserver(observer)
      }
      releaseBackgroundTask()
    }

    private var isRunning: Bool {
      lock.lock()
      defer { lock.unlock() }
      return !released
    }

    private var hasResigned: Bool {
      lock.lock()
      defer { lock.unlock() }
      return resigned
    }

    private func markResigned() {
      lock.lock()
      resigned = true
      lock.unlock()
    }

    private func releaseBackgroundTask() {
      lock.lock()
      released = true
      let id = taskID
      taskID = .invalid
      lock.unlock()
      if id != .invalid {
        UIApplication.shared.endBackgroundTask(id)
      }
    }
  }

  /// Waits for `didBecomeActive`, or returns at once when the app already is
  /// active — or, given `orBackgroundTimeLeft`, has at least that much
  /// background time left.
  final class UIKitActiveWaiter: @unchecked Sendable {
    private let minimumBackgroundTime: TimeInterval?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?
    private var observer: NSObjectProtocol?

    init(orBackgroundTimeLeft minimumBackgroundTime: TimeInterval? = nil) {
      self.minimumBackgroundTime = minimumBackgroundTime
    }

    func wait() async throws {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          lock.lock()
          if let outcome {
            lock.unlock()
            cont.resume(with: outcome)
            return
          }
          continuation = cont
          lock.unlock()

          DispatchQueue.main.async {
            // Observing before reading the state, so a transition between the
            // two cannot be missed.
            let observer = NotificationCenter.default.addObserver(
              forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
              self?.finish(.success(()))
            }
            self.lock.lock()
            let finished = self.outcome != nil
            if !finished { self.observer = observer }
            self.lock.unlock()
            if finished {
              NotificationCenter.default.removeObserver(observer)
              return
            }
            let app = UIApplication.shared
            // `backgroundTimeRemaining` is unbounded outside the background.
            if app.applicationState == .active
              || self.minimumBackgroundTime.map({ app.backgroundTimeRemaining >= $0 }) == true
            {
              self.finish(.success(()))
            }
          }
        }
      } onCancel: {
        finish(.failure(CancellationError()))
      }
    }

    private func finish(_ result: Result<Void, Error>) {
      lock.lock()
      guard outcome == nil else {
        lock.unlock()
        return
      }
      outcome = result
      let continuation = self.continuation
      self.continuation = nil
      let observer = self.observer
      self.observer = nil
      lock.unlock()
      if let observer {
        NotificationCenter.default.removeObserver(observer)
      }
      continuation?.resume(with: result)
    }
  }
#endif
