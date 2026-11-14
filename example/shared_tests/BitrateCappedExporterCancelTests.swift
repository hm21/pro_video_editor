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
class BitrateCappedExporterCancelTests: XCTestCase {
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
    let finished = expectation(description: "finished")

    for _ in 0..<2 {
      BitrateCappedExporter.cancelOffCallerThread(
        session: gate,
        teardown: { lock.withLock { teardowns += 1 } },
        finish: { finished.fulfill() })
    }

    wait(for: [finished], timeout: 5)
    XCTAssertEqual(lock.withLock { teardowns }, 1)
  }

  func testCancelDoesNotFinishWhileAnotherCancelIsTearingDown() {
    let gate = BitrateCappedExporter.SessionGate()
    let tearingDown = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let secondFinished = DispatchSemaphore(value: 0)
    let finished = expectation(description: "first cancel finished")

    BitrateCappedExporter.cancelOffCallerThread(
      session: gate,
      teardown: {
        tearingDown.signal()
        release.wait()
      },
      finish: { finished.fulfill() })
    XCTAssertEqual(tearingDown.wait(timeout: .now() + 5), .success)

    BitrateCappedExporter.cancelOffCallerThread(
      session: gate,
      teardown: { XCTFail("the second cancel must not tear down") },
      finish: { secondFinished.signal() })
    let prematureFinish = secondFinished.wait(timeout: .now() + 1)
    release.signal()
    wait(for: [finished], timeout: 5)
    XCTAssertEqual(prematureFinish, .timedOut, "completion ran before teardown ended")
  }

  func testCancelLeavesCompletionToTheFinalizingWriter() {
    let gate = BitrateCappedExporter.SessionGate()
    // The normal completion path has claimed the writer for finishWriting.
    XCTAssertTrue(gate.end())
    let finished = expectation(description: "cancel must not finish the export")
    finished.isInverted = true

    BitrateCappedExporter.cancelOffCallerThread(
      session: gate,
      teardown: { XCTFail("the finalizing writer must not be torn down") },
      finish: { finished.fulfill() })

    wait(for: [finished], timeout: 1)
  }
}
