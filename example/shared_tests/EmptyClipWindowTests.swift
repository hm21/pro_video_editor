import AVFoundation
import XCTest

@testable import pro_video_editor

// Compiled into *both* the iOS and the macOS RunnerTests target (referenced
// from each project as ../shared_tests/…).

/// A clip whose window holds no time, whether it came in that way or a loop
/// wrap took all of it, is left out of the render. Inserting its empty range
/// failed the whole render with AVFoundationErrorDomain -11800, underlying
/// OSStatus -12780.
final class EmptyClipWindowTests: XCTestCase {
  private var source: URL!

  override func setUpWithError() throws {
    // Three seconds, one color each.
    source = try ThumbnailTimestampFixture.makeColorVideo(
      colors: Array(ThumbnailTimestampFixture.palette.prefix(3)))
  }

  override func tearDown() {
    if let source { try? FileManager.default.removeItem(at: source) }
    super.tearDown()
  }

  func testAClipThatEndsWhereItStartsIsLeftOut() async throws {
    let duration = try await renderedDuration([
      clip(startUs: 0, endUs: 1_000_000),
      clip(startUs: 2_000_000, endUs: 2_000_000),
      clip(startUs: 1_000_000, endUs: 2_000_000),
    ])

    XCTAssertEqual(duration, 2.0, accuracy: 0.05)
  }

  func testAClipThatEndsAtZeroIsLeftOut() async throws {
    let duration = try await renderedDuration([
      clip(startUs: nil, endUs: 0),
      clip(startUs: 1_000_000, endUs: 2_000_000),
    ])

    XCTAssertEqual(duration, 1.0, accuracy: 0.05)
  }

  func testOnlyEmptyClipsFailWithTheirOwnError() async throws {
    let error = try await renderError([
      clip(startUs: nil, endUs: 0),
      clip(startUs: 1_000_000, endUs: 1_000_000),
    ])

    let nsError = try XCTUnwrap(error) as NSError
    XCTAssertEqual(nsError.domain, "RenderVideo")
    XCTAssertEqual(nsError.localizedDescription, "Every video clip has an empty time range")
  }

  func testALoopWrapThatTakesTheWholeFirstClipLeavesItOut() async throws {
    // The 200 ms first clip is shorter than the 400 ms wrap, so the blend takes
    // all of it: 1.8 s of the last clip, then the 200 ms blend.
    let duration = try await renderedDuration([
      clip(startUs: 1_000_000, endUs: 1_200_000),
      clip(startUs: 0, endUs: 2_000_000, wrapUs: 400_000),
    ])

    XCTAssertEqual(duration, 2.0, accuracy: 0.05)
  }

  func testALoopWrapThatTakesTheWholeLastClipLeavesItOut() async throws {
    // The wrap takes the whole 200 ms last clip and 200 ms of the first one.
    let duration = try await renderedDuration([
      clip(startUs: 0, endUs: 2_000_000),
      clip(startUs: 1_000_000, endUs: 1_200_000, wrapUs: 400_000),
    ])

    XCTAssertEqual(duration, 2.0, accuracy: 0.05)
  }

  private func clip(startUs: Int64?, endUs: Int64, wrapUs: Int64? = nil) -> [String: Any] {
    var clip: [String: Any] = ["inputPath": source.path, "endUs": endUs]
    if let startUs { clip["startUs"] = startUs }
    if let wrapUs { clip["transition"] = ["type": "dissolve", "durationUs": wrapUs] }
    return clip
  }

  /// Renders `clips` through the bitrate-capped path, the one an export takes,
  /// and returns the output's length in seconds.
  private func renderedDuration(_ clips: [[String: Any]]) async throws -> Double {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("pve_empty_window_\(UUID().uuidString).mp4")
    let failure = try await renderError(clips, output: output)
    let duration = try? await AVURLAsset(url: output).load(.duration).seconds
    try? FileManager.default.removeItem(at: output)
    if let failure { throw failure }
    return try XCTUnwrap(duration)
  }

  private func renderError(_ clips: [[String: Any]], output: URL? = nil) async throws -> Error? {
    let output =
      output
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("pve_empty_window_\(UUID().uuidString).mp4")
    let config = try XCTUnwrap(
      RenderConfig.fromArguments([
        "videoClips": clips, "outputPath": output.path, "outputFormat": "mp4",
        "bitrate": 2_000_000,
      ]))
    let settled = expectation(description: "render settles")
    var failure: Error?
    RenderVideo.render(
      config: config, onProgress: { _ in },
      onComplete: { _ in settled.fulfill() },
      onError: {
        failure = $0
        settled.fulfill()
      })
    await fulfillment(of: [settled], timeout: 120)
    return failure
  }
}
