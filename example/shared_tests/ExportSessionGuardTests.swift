import AVFoundation
import Foundation
import XCTest

@testable import pro_video_editor

// Compiled into *both* the iOS and the macOS RunnerTests target (referenced
// from each project as ../shared_tests/…). The guard it covers is one piece of
// shared Darwin code, and a duplicated copy would let one platform's suite stay
// green while the other quietly stopped testing the invariant.
//
// Keep it free of platform imports (no UIKit/Cocoa, no Flutter/FlutterMacOS)
// and of anything that is not in both targets — `ThumbnailTimestampFixture`,
// which each RunnerTests.swift defines, is the one exception.

// MARK: - Export session start guard

/// `AVAssetExportSession.export(to:as:)` assigns `outputURL` before it starts,
/// and AVFoundation answers that assignment on a session that already left
/// `.unknown` with an Objective-C exception Swift cannot catch — it takes the
/// host app down with it. These pin the rules that keep the call from ever
/// being made: nothing force-cancels a session that has yet to run, every
/// session a job attaches starts out unclaimed, and the guard refuses to start
/// one that is not startable.
class ExportSessionGuardTests: XCTestCase {
  /// The fixture the sessions below export. Authored once for the whole class:
  /// most of these tests never start an export at all, and the ones that do can
  /// share a single source.
  private static var sharedSource: URL?

  private var temporaryFiles: [URL] = []

  override class func tearDown() {
    if let source = sharedSource {
      try? FileManager.default.removeItem(at: source)
      sharedSource = nil
    }
    super.tearDown()
  }

  override func tearDown() {
    for url in temporaryFiles {
      try? FileManager.default.removeItem(at: url)
    }
    temporaryFiles = []
    super.tearDown()
  }

  private func fixtureSource() throws -> URL {
    if let existing = ExportSessionGuardTests.sharedSource { return existing }
    let created = try ThumbnailTimestampFixture.makeColorVideo(colors: [(215, 40, 40)])
    ExportSessionGuardTests.sharedSource = created
    return created
  }

  /// A real, runnable passthrough session over the shared one-second fixture.
  private func makeSession() throws -> AVAssetExportSession {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("pve_guard_\(UUID().uuidString).mp4")
    temporaryFiles.append(output)

    guard
      let export = AVAssetExportSession(
        asset: AVURLAsset(url: try fixtureSource()),
        presetName: AVAssetExportPresetPassthrough)
    else {
      throw NSError(domain: "ExportSessionGuardTests", code: 1)
    }
    export.outputURL = output
    export.outputFileType = .mp4
    return export
  }

  func testCancelBeforeTheStartLeavesTheSessionUntouched() throws {
    let export = try makeSession()
    let handle = RenderJobHandle()
    handle.attach(export: export)

    handle.cancel()

    // The crash precondition: force-cancelling here moves the session to
    // `.cancelled`, which the queued `export(to:as:)` then reads as "already
    // started" and answers with an uncatchable exception.
    XCTAssertEqual(export.status, .unknown)
  }

  /// The same rule from the other side, for the callers that force-cancel
  /// without a handle — the stall/timeout hooks of `ExportWatchdog`, whose
  /// bounds can be tight enough to fire while the session is still queued.
  func testForceCancellingAnUnstartedSessionIsRefused() throws {
    let export = try makeSession()

    XCTAssertFalse(
      ExportSessionGuard.forceCancel(export),
      "a session that never ran has nothing to cancel")
    XCTAssertEqual(export.status, .unknown)
  }

  /// A job attaches more than one session over its life — the two halves of a
  /// split, or a passthrough attempt and the full render it falls back to. The
  /// claim must not carry over, or a cancel landing on the second session would
  /// force-cancel one that never ran and reintroduce the crash.
  func testASessionAttachedAfterAClaimedOneStartsOutUnclaimed() throws {
    let first = try makeSession()
    let second = try makeSession()
    let handle = RenderJobHandle()

    handle.attach(export: first)
    XCTAssertTrue(handle.beginExport(), "the first session must claim its start")

    handle.attach(export: second)
    handle.cancel()

    XCTAssertEqual(second.status, .unknown, "the freshly attached session must be left alone")
  }

  func testStartIsRefusedAfterTheJobWasCancelled() async throws {
    let export = try makeSession()
    let handle = RenderJobHandle()
    handle.attach(export: export)

    handle.cancel()

    do {
      try await ExportSessionDriver.run(
        export, handle: handle, label: "Test", failureDomain: "Test")
      XCTFail("A cancelled job must not start its export")
    } catch is CancellationError {
      // Expected — cancellation is a normal outcome, not a failure.
    }
    XCTAssertEqual(export.status, .unknown, "the export must never have run")
  }

  func testAnAlreadyCancelledSessionIsRefusedWithoutAHandle() throws {
    let export = try makeSession()
    export.cancelExport()

    XCTAssertThrowsError(try ExportSessionGuard.claimStart(export, label: "Test")) { error in
      XCTAssertTrue(error is CancellationError)
    }
  }

  func testAClaimedJobRunsToCompletion() async throws {
    let export = try makeSession()
    let handle = RenderJobHandle()
    handle.attach(export: export)

    // The progress observer is part of what is under test: the driver has to
    // tear it down, so a run that leaks it hangs here instead of returning.
    let progress = ProgressBox()
    try await ExportSessionDriver.run(
      export, handle: handle, label: "Test", failureDomain: "Test",
      onProgress: { progress.update($0) })

    XCTAssertEqual(export.status, .completed)
  }

  func testStartingASpentSessionTwiceIsAnErrorInsteadOfACrash() async throws {
    let export = try makeSession()
    try await ExportSessionDriver.run(export, label: "Test", failureDomain: "Test")

    do {
      try await ExportSessionDriver.run(export, label: "Test", failureDomain: "Test")
      XCTFail("A spent session must not be started again")
    } catch let error as NSError {
      XCTAssertEqual(error.domain, ExportSessionGuard.errorDomain)
    }
  }
}
