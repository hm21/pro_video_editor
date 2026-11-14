import Foundation
import XCTest

@testable import pro_video_editor

// Compiled into *both* the iOS and the macOS RunnerTests target, like the
// other files in shared_tests.

/// Cancelling a bitrate-capped export never waits for a pump.
///
/// A pump holds the export's gate for a whole `copyNextSampleBuffer`, and a
/// custom compositor can keep that call waiting indefinitely. Cancellation
/// runs on whichever thread cancels — the platform thread for a `cancelTask`
/// from Dart — so a cancel that waited for the gate froze the host app.
///
/// A cancel that loses the session runs `finish` again once its grace is
/// over, so these tests count `finish` calls with semaphores, never with an
/// `XCTestExpectation` that a late call would over-fulfill after the test.
class BitrateCappedExporterCancelTests: XCTestCase {
  /// Longer than any of these tests waits, so a losing cancel never gives up
  /// while a test is still looking.
  private let longGrace: TimeInterval = 60

  /// A pump stuck in a read: holds [gate] until [release] is signalled.
  private func holdGate(
    _ gate: BitrateCappedExporter.SessionGate,
    until release: DispatchSemaphore
  ) {
    let holding = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      gate.whileLive {
        holding.signal()
        release.wait()
      }
    }
    XCTAssertEqual(holding.wait(timeout: .now() + 5), .success, "the pump never took the gate")
  }

  /// Calls `cancelOffCallerThread` on its own thread and reports whether
  /// that call came back within [timeout], so a cancel that blocks fails the
  /// test instead of hanging it.
  private func cancelReturns(
    within timeout: TimeInterval,
    _ cancel: @escaping () -> Void
  ) -> Bool {
    let returned = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      cancel()
      returned.signal()
    }
    return returned.wait(timeout: .now() + timeout) == .success
  }

  func testCancelReturnsWhileAPumpHoldsTheGate() {
    let gate = BitrateCappedExporter.SessionGate()
    let release = DispatchSemaphore(value: 0)
    holdGate(gate, until: release)
    let tornDown = expectation(description: "torn down")
    let finished = expectation(description: "finished")

    let returned = cancelReturns(within: 1) {
      BitrateCappedExporter.cancelOffCallerThread(
        session: gate,
        grace: self.longGrace,
        teardown: { tornDown.fulfill() },
        finish: { finished.fulfill() })
    }

    XCTAssertTrue(returned, "cancel waited for the pump to release the gate")
    release.signal()
    wait(for: [tornDown, finished], timeout: 5, enforceOrder: true)
  }

  func testTeardownWaitsForThePumpAndRunsBeforeFinish() {
    let gate = BitrateCappedExporter.SessionGate()
    let release = DispatchSemaphore(value: 0)
    holdGate(gate, until: release)
    let lock = NSLock()
    var events: [String] = []
    let finished = expectation(description: "finished")

    let returned = cancelReturns(within: 1) {
      BitrateCappedExporter.cancelOffCallerThread(
        session: gate,
        grace: self.longGrace,
        teardown: { lock.withLock { events.append("teardown") } },
        finish: {
          lock.withLock { events.append("finish") }
          finished.fulfill()
        })
    }

    XCTAssertTrue(returned, "cancel waited for the pump to release the gate")
    // The pump is still reading: tearing the reader down now is the
    // `EXC_BAD_ACCESS` the gate exists to prevent.
    XCTAssertEqual(lock.withLock { events }, [], "teardown ran inside the pump's read")

    release.signal()
    wait(for: [finished], timeout: 5)
    XCTAssertEqual(lock.withLock { events }, ["teardown", "finish"])
  }

  func testOnlyTheFirstCancelTearsDown() {
    let gate = BitrateCappedExporter.SessionGate()
    let lock = NSLock()
    var teardowns = 0
    let finished = DispatchSemaphore(value: 0)

    for _ in 0..<2 {
      BitrateCappedExporter.cancelOffCallerThread(
        session: gate,
        grace: longGrace,
        teardown: { lock.withLock { teardowns += 1 } },
        finish: { finished.signal() })
    }

    XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(finished.wait(timeout: .now() + 0.5), .timedOut, "the losing cancel finished")
    XCTAssertEqual(lock.withLock { teardowns }, 1)
  }

  func testCancelDoesNotFinishWhileAnotherCancelIsTearingDown() {
    let gate = BitrateCappedExporter.SessionGate()
    let tearingDown = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let firstFinished = DispatchSemaphore(value: 0)
    let secondFinished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var secondTeardowns = 0

    BitrateCappedExporter.cancelOffCallerThread(
      session: gate,
      grace: longGrace,
      teardown: {
        tearingDown.signal()
        release.wait()
      },
      finish: { firstFinished.signal() })
    XCTAssertEqual(tearingDown.wait(timeout: .now() + 5), .success)

    BitrateCappedExporter.cancelOffCallerThread(
      session: gate,
      grace: longGrace,
      teardown: { lock.withLock { secondTeardowns += 1 } },
      finish: { secondFinished.signal() })
    let prematureFinish = secondFinished.wait(timeout: .now() + 1)
    release.signal()
    XCTAssertEqual(firstFinished.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(prematureFinish, .timedOut, "completion ran before teardown ended")
    XCTAssertEqual(lock.withLock { secondTeardowns }, 0, "the second cancel tore down")
  }

  func testCancelLeavesCompletionToTheFinalizingWriter() {
    let gate = BitrateCappedExporter.SessionGate()
    // The normal completion path has claimed the writer for finishWriting.
    XCTAssertTrue(gate.end())
    let finished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var teardowns = 0

    BitrateCappedExporter.cancelOffCallerThread(
      session: gate,
      grace: longGrace,
      teardown: { lock.withLock { teardowns += 1 } },
      finish: { finished.signal() })

    XCTAssertEqual(
      finished.wait(timeout: .now() + 1), .timedOut,
      "cancel finished the export while the writer was finalizing")
    XCTAssertEqual(lock.withLock { teardowns }, 0, "the finalizing writer was torn down")
  }

  /// A `finishWriting` stuck behind a wedged encoder never calls back. The
  /// cancel must still complete the export, or the task would hold the
  /// process-wide export gate forever.
  func testCancelGivesUpOnAFinalizingWriterThatNeverReports() {
    let gate = BitrateCappedExporter.SessionGate()
    XCTAssertTrue(gate.end())
    let finished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var teardowns = 0

    let start = Date()
    BitrateCappedExporter.cancelOffCallerThread(
      session: gate,
      grace: 0.3,
      teardown: { lock.withLock { teardowns += 1 } },
      finish: { finished.signal() })

    XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "cancel never gave up")
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3, "gave up before the grace")
    XCTAssertEqual(lock.withLock { teardowns }, 0, "the finalizing writer was torn down")
  }
}
