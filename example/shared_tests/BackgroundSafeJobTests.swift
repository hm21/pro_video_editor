import AVFoundation
import Foundation
import ImageIO
import XCTest

@testable import pro_video_editor

// Compiled into *both* the iOS and the macOS RunnerTests target, like the
// other files in shared_tests. The app is faked, so the restart rules are
// checked the same way on both platforms; whether iOS really suspends and
// interrupts an export can only be seen on a device.

/// A job that ends because the app left the foreground starts over once the
/// app is active again; every other outcome reaches the caller as it is.
class BackgroundSafeJobTests: XCTestCase {
  private struct Interrupted: Error {}
  private struct Broken: Error {}

  /// An app whose attempts report a scripted `leftForeground` answer, and
  /// whose background time a test can run out.
  private final class FakeApp: @unchecked Sendable {
    private let lock = NSLock()
    private var leftForegroundByAttempt: [Bool]
    private var expiryHandlers: [() -> Void] = []
    private var _ended = 0
    private var _startChecks = 0
    private var _waits = 0
    private let startBlocks: Bool
    private let returnBlocks: Bool

    /// `startBlocks` / `returnBlocks` keep the app from ever making room to
    /// start, or from ever coming back, until the waiting task is cancelled.
    init(leftForeground: [Bool], startBlocks: Bool = false, returnBlocks: Bool = false) {
      self.leftForegroundByAttempt = leftForeground
      self.startBlocks = startBlocks
      self.returnBlocks = returnBlocks
    }

    var ended: Int { lock.sync { _ended } }
    var startChecks: Int { lock.sync { _startChecks } }
    var waits: Int { lock.sync { _waits } }

    /// Runs out the background time of attempt `index`, as iOS does.
    func expire(attempt index: Int) {
      let handler = lock.sync { expiryHandlers[index] }
      handler()
    }

    var environment: AppEnvironment {
      AppEnvironment(
        beginActivity: { _, onExpired in self.beginActivity(onExpired) },
        waitUntilWorkCanStart: {
          self.lock.sync { self._startChecks += 1 }
          if self.startBlocks {
            try await Task.sleep(nanoseconds: 60_000_000_000)
          }
        },
        waitUntilActive: {
          self.lock.sync { self._waits += 1 }
          if self.returnBlocks {
            try await Task.sleep(nanoseconds: 60_000_000_000)
          }
        })
    }

    private func beginActivity(_ onExpired: @escaping () -> Void) -> AppActivity {
      lock.sync {
        let index = expiryHandlers.count
        let left =
          index < leftForegroundByAttempt.count ? leftForegroundByAttempt[index] : false
        expiryHandlers.append(onExpired)
        return FakeActivity(left: left) { [weak self] in
          self?.lock.sync { self?._ended += 1 }
        }
      }
    }
  }

  private final class FakeActivity: AppActivity {
    private let left: Bool
    private let onEnd: () -> Void

    init(left: Bool, onEnd: @escaping () -> Void) {
      self.left = left
      self.onEnd = onEnd
    }

    func leftForeground() async -> Bool { left }
    func end() { onEnd() }
  }

  /// How one attempt ends: on its own, or by being cancelled through the
  /// handle it was given, the way a render unwinds.
  private enum Outcome {
    case succeed(String)
    case fail(Error)
    case runUntilCancelled
  }

  /// Runs a job whose attempts end with `outcomes`, in order, reporting
  /// asynchronously the way the render queue does. `whileRunning` is called
  /// once attempt `index` is underway.
  private func runJob(
    app: FakeApp,
    handle: RenderJobHandle = RenderJobHandle(),
    outcomes: [Outcome],
    whileRunning: ((Int) -> Void)? = nil
  ) -> (result: Result<String, Error>?, attempts: Int) {
    let lock = NSLock()
    var attempts = 0
    var reported: Result<String, Error>?
    let done = expectation(description: "job reported")

    BackgroundSafeJob.run(
      label: "Test", handle: handle, environment: app.environment,
      attempt: { attemptHandle, onComplete, onError in
        let index = lock.sync { () -> Int in
          attempts += 1
          return attempts - 1
        }
        let task = Task {
          switch outcomes[min(index, outcomes.count - 1)] {
          case .succeed(let value): onComplete(value)
          case .fail(let error): onError(error)
          case .runUntilCancelled:
            while !Task.isCancelled {
              try? await Task.sleep(nanoseconds: 1_000_000)
            }
            onError(CancellationError())
          }
        }
        attemptHandle.attach(task: task)
        whileRunning?(index)
      },
      onComplete: { value in
        lock.sync { reported = .success(value) }
        done.fulfill()
      },
      onError: { error in
        lock.sync { reported = .failure(error) }
        done.fulfill()
      })

    wait(for: [done], timeout: 10)
    return lock.sync { (reported, attempts) }
  }

  func testCompletesInOneAttempt() throws {
    let app = FakeApp(leftForeground: [false])

    let (result, attempts) = runJob(app: app, outcomes: [.succeed("video")])

    XCTAssertEqual(try result?.get(), "video")
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(app.startChecks, 1)
    XCTAssertEqual(app.waits, 0)
    XCTAssertEqual(app.ended, 1, "the attempt's background task is ended")
  }

  func testFailureWhileInTheForegroundIsReported() {
    let app = FakeApp(leftForeground: [false])

    let (result, attempts) = runJob(app: app, outcomes: [.fail(Broken())])

    guard case .failure(let error) = result else {
      return XCTFail("expected the failure, got \(String(describing: result))")
    }
    XCTAssertTrue(error is Broken)
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(app.waits, 0, "nothing waits for an app that never left")
    XCTAssertEqual(app.ended, 1)
  }

  func testAttemptInterruptedByLeavingTheAppStartsOverOnceActive() throws {
    let app = FakeApp(leftForeground: [true, false])

    let (result, attempts) = runJob(
      app: app, outcomes: [.fail(Interrupted()), .succeed("video")])

    XCTAssertEqual(try result?.get(), "video")
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(app.waits, 1)
    XCTAssertEqual(app.startChecks, 1, "a restart waits for the app, not for room to start")
    XCTAssertEqual(app.ended, 2, "each attempt ends its own background task")
  }

  func testStartsOverEveryTimeTheAppIsLeft() throws {
    let app = FakeApp(leftForeground: [true, true, true, false])

    let (result, attempts) = runJob(
      app: app,
      outcomes: [
        .fail(Interrupted()), .fail(Interrupted()), .fail(Interrupted()), .succeed("video"),
      ])

    XCTAssertEqual(try result?.get(), "video")
    XCTAssertEqual(attempts, 4)
    XCTAssertEqual(app.waits, 3)
  }

  func testRestartThatFailsInTheForegroundReportsThatFailure() {
    let app = FakeApp(leftForeground: [true, false])

    let (result, attempts) = runJob(
      app: app, outcomes: [.fail(Interrupted()), .fail(Broken())])

    guard case .failure(let error) = result else {
      return XCTFail("expected the failure, got \(String(describing: result))")
    }
    XCTAssertTrue(error is Broken)
    XCTAssertEqual(attempts, 2)
  }

  func testBackgroundTimeRunningOutStopsTheAttemptAndStartsItOver() throws {
    let app = FakeApp(leftForeground: [true, false])
    let handle = RenderJobHandle()

    let (result, attempts) = runJob(
      app: app, handle: handle, outcomes: [.runUntilCancelled, .succeed("video")],
      whileRunning: { index in
        if index == 0 { app.expire(attempt: 0) }
      })

    XCTAssertEqual(try result?.get(), "video")
    XCTAssertEqual(attempts, 2)
    XCTAssertFalse(handle.isCanceled, "only the attempt was stopped, not the job")
  }

  func testCancellingTheJobStopsItsRunningAttempt() {
    let app = FakeApp(leftForeground: [false])
    let handle = RenderJobHandle()

    let (result, attempts) = runJob(
      app: app, handle: handle, outcomes: [.runUntilCancelled],
      whileRunning: { _ in handle.cancel() })

    guard case .failure(let error) = result else {
      return XCTFail("expected the cancellation, got \(String(describing: result))")
    }
    XCTAssertTrue(error is CancellationError)
    XCTAssertEqual(attempts, 1)
  }

  func testCancelledJobIsNotStartedOver() {
    let app = FakeApp(leftForeground: [true])
    let handle = RenderJobHandle()

    let (result, attempts) = runJob(
      app: app, handle: handle, outcomes: [.fail(Interrupted())],
      whileRunning: { _ in handle.cancel() })

    guard case .failure(let error) = result else {
      return XCTFail("expected the failure, got \(String(describing: result))")
    }
    XCTAssertTrue(error is Interrupted)
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(app.waits, 0)
  }

  func testCancelWhileWaitingForTheAppToReturnEndsTheJob() {
    let app = FakeApp(leftForeground: [true], returnBlocks: true)
    let handle = RenderJobHandle()
    let lock = NSLock()
    var attempts = 0
    var reported: Error?
    let done = expectation(description: "job reported")

    BackgroundSafeJob.run(
      label: "Test", handle: handle, environment: app.environment,
      attempt: { _, _, onError in
        lock.sync { attempts += 1 }
        Task { onError(Interrupted()) }
      },
      onComplete: { (_: String) in
        XCTFail("a cancelled job must not complete")
        done.fulfill()
      },
      onError: { error in
        lock.sync { reported = error }
        done.fulfill()
      })

    // Cancel once the job is parked waiting for the app to come back.
    let deadline = Date().addingTimeInterval(5)
    while app.waits == 0, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertEqual(app.waits, 1)
    handle.cancel()

    wait(for: [done], timeout: 10)
    XCTAssertTrue(lock.sync { reported } is CancellationError)
    XCTAssertEqual(lock.sync { attempts }, 1)
  }

  func testCancelBeforeTheJobMayStartEndsItWithoutAnAttempt() {
    let app = FakeApp(leftForeground: [], startBlocks: true)
    let handle = RenderJobHandle()
    let lock = NSLock()
    var attempts = 0
    var reported: Error?
    let done = expectation(description: "job reported")

    BackgroundSafeJob.run(
      label: "Test", handle: handle, environment: app.environment,
      attempt: { (_, _, _: @escaping (Error) -> Void) in
        lock.sync { attempts += 1 }
      },
      onComplete: { (_: String) in
        XCTFail("a cancelled job must not complete")
        done.fulfill()
      },
      onError: { error in
        lock.sync { reported = error }
        done.fulfill()
      })

    // Cancel once the job is parked waiting for room to start.
    let deadline = Date().addingTimeInterval(5)
    while app.startChecks == 0, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertEqual(app.startChecks, 1)
    handle.cancel()

    wait(for: [done], timeout: 10)
    XCTAssertTrue(lock.sync { reported } is CancellationError)
    XCTAssertEqual(lock.sync { attempts }, 0)
  }
}

/// An attempt started over writes to the output path of the one before it, so
/// both jobs ``BackgroundSafeJob`` runs must replace the partial file left
/// there.
final class RestartOutputTests: XCTestCase {
  private func makePartialOutput() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pve_partial_\(UUID().uuidString).mp4")
    try Data("partial".utf8).write(to: url)
    return url
  }

  private func videoSeconds(_ url: URL) async throws -> Double {
    let track = try await MediaInfoExtractor.loadVideoTrack(from: AVURLAsset(url: url))
    return await TrackEndTrimmer.timeRange(of: track).duration.seconds
  }

  func testRenderReplacesAFileAtTheOutputPath() async throws {
    let palette = ThumbnailTimestampFixture.palette
    let source = try ThumbnailTimestampFixture.makeColorVideo(colors: [palette[0]])
    defer { try? FileManager.default.removeItem(at: source) }
    let output = try makePartialOutput()
    defer { try? FileManager.default.removeItem(at: output) }

    // No bitrate cap: the export-session path, the one that refused the file.
    let config = try XCTUnwrap(
      RenderConfig.fromArguments([
        "videoClips": [["inputPath": source.path]],
        "outputPath": output.path,
        "outputFormat": "mp4",
        "enableAudio": false,
      ]))
    let settled = expectation(description: "render settles")
    var failure: Error?
    RenderVideo.render(
      config: config,
      onProgress: { _ in },
      onComplete: { _ in settled.fulfill() },
      onError: { error in
        failure = error
        settled.fulfill()
      })
    await fulfillment(of: [settled], timeout: 120)

    XCTAssertNil(failure)
    let seconds = try await videoSeconds(output)
    XCTAssertEqual(seconds, 1, accuracy: 0.1)
  }

  func testStopMotionReplacesAFileAtTheOutputPath() async throws {
    let frame = FileManager.default.temporaryDirectory
      .appendingPathComponent("pve_frame_\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: frame) }
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(frame as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))

    let output = try makePartialOutput()
    defer { try? FileManager.default.removeItem(at: output) }

    let config = try XCTUnwrap(
      StopMotionConfig.fromArguments([
        "id": "restart-output",
        "frames": [["imagePath": frame.path], ["imagePath": frame.path]],
        "frameRate": NSNumber(value: 2),
        "outputPath": output.path,
      ]))
    let settled = expectation(description: "stop-motion render settles")
    var failure: Error?
    StopMotionGenerator.generate(
      config: config,
      onProgress: { _ in },
      onComplete: { _ in settled.fulfill() },
      onError: { error in
        failure = error
        settled.fulfill()
      })
    await fulfillment(of: [settled], timeout: 60)

    XCTAssertNil(failure)
    let seconds = try await videoSeconds(output)
    XCTAssertEqual(seconds, 1, accuracy: 0.1, "two frames at 2 fps")
  }
}

extension NSLock {
  fileprivate func sync<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
