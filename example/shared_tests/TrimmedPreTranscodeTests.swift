import AVFoundation
import Foundation
import XCTest

@testable import pro_video_editor

// Compiled into *both* the iOS and the macOS RunnerTests target (referenced
// from each project as ../shared_tests/…), like ExportSessionGuardTests.swift:
// the pre-transcode is shared Darwin code. `ThumbnailTimestampFixture`, which
// each RunnerTests.swift defines, is the one outside dependency.

// MARK: - Pre-transcode window arithmetic (#192)

/// Which part of an HDR source the pre-transcode encodes for the clips that
/// play it: only their windows when those are a small part of it, otherwise
/// the whole source, exactly as before windows were considered.
final class TranscodePlanTests: XCTestCase {
  private typealias Range = VideoTranscoder.SourceRange

  private let second: Int64 = 1_000_000

  private func plan(
    _ windows: [(startUs: Int64?, endUs: Int64?)], of durationUs: Int64 = 10_000_000
  ) -> [Range?] {
    VideoTranscoder.plannedRanges(for: windows, sourceDurationUs: durationUs)
  }

  func testAShortWindowIsEncodedOnItsOwn() {
    XCTAssertEqual(
      plan([(2 * second, 4 * second)]), [Range(startUs: 2 * second, endUs: 4 * second)])
  }

  func testAnOpenEndRunsToTheEndOfTheSource() {
    XCTAssertEqual(
      plan([(8 * second, nil)]), [Range(startUs: 8 * second, endUs: 10 * second)])
    XCTAssertEqual(plan([(nil, 1 * second)]), [Range(startUs: 0, endUs: 1 * second)])
  }

  func testAnUntrimmedClipEncodesTheWholeSource() {
    XCTAssertEqual(plan([(nil, nil)]), [nil])
    XCTAssertEqual(plan([(0, 10 * second)]), [nil])
  }

  func testAWindowOfNinetyPercentOrMoreEncodesTheWholeSource() {
    XCTAssertEqual(plan([(0, 9 * second)]), [nil])
    XCTAssertEqual(plan([(0, 9 * second - 1)]), [Range(startUs: 0, endUs: 9 * second - 1)])
  }

  func testClipsSharingAWindowResolveToOneRange() {
    let ranges = plan([(1 * second, 3 * second), (1 * second, 3 * second)])
    XCTAssertEqual(ranges[0], Range(startUs: 1 * second, endUs: 3 * second))
    XCTAssertEqual(ranges[0], ranges[1])
  }

  func testDistinctWindowsGetTheirOwnRanges() {
    XCTAssertEqual(
      plan([(0, 2 * second), (5 * second, 7 * second)]),
      [
        Range(startUs: 0, endUs: 2 * second),
        Range(startUs: 5 * second, endUs: 7 * second),
      ])
  }

  func testWindowsThatTogetherCoverTheSourceShareTheWholeTranscode() {
    // 5 s + 5 s of a 10 s source: encoding each on its own would re-encode all
    // of it piecewise.
    XCTAssertEqual(plan([(0, 5 * second), (5 * second, 10 * second)]), [nil, nil])
    // Overlaps count once per distinct window, so they tip the balance early.
    XCTAssertEqual(plan([(0, 5 * second), (1 * second, 6 * second)]), [nil, nil])
  }

  func testAnUnknownDurationEncodesTheWholeSource() {
    XCTAssertEqual(plan([(0, 1 * second)], of: 0), [nil])
  }

  func testAWindowOutsideTheSourceTakesEveryClipOfItToTheWholeSource() {
    XCTAssertEqual(plan([(12 * second, 14 * second)]), [nil])
    XCTAssertEqual(plan([(0, 1 * second), (12 * second, 14 * second)]), [nil, nil])
    XCTAssertEqual(plan([(3 * second, 3 * second)]), [nil])
  }

  func testAWindowPastTheEndIsClampedToTheSource() {
    XCTAssertEqual(
      plan([(7 * second, 20 * second)]), [Range(startUs: 7 * second, endUs: 10 * second)])
  }

  func testTheWindowOfATrackRoundsOutwardsToWholeMicroseconds() {
    // 31 frames at 29.97 fps, starting a quarter of a microsecond in: it ends
    // at 1_034_366.916… µs, which truncation would cut to 1_034_366.
    let range = CMTimeRange(
      start: CMTime(value: 1, timescale: 4_000_000),
      duration: CMTime(value: 31 * 1001, timescale: 30_000))
    let window = VideoTranscoder.window(covering: range)
    XCTAssertEqual(window.startUs, 0)
    XCTAssertEqual(window.endUs, 1_034_367)
  }
}

// MARK: - Trimmed pre-transcode on a real encode (#192)

/// The pre-transcode end to end on an HDR-tagged clip whose every second is a
/// different color, so a window can be recognised in the file it produced.
final class TrimmedPreTranscodeTests: XCTestCase {
  private static let fps: Int32 = 30

  /// Six seconds, one palette color each.
  private func makeHdrSource() async throws -> URL {
    let palette = ThumbnailTimestampFixture.palette
    let source: URL
    do {
      // HEVC tagged BT.2020 is what `needsTranscodingForEffects` keys on; the
      // pixels themselves stay 8-bit.
      source = try ThumbnailTimestampFixture.makeColorVideo(
        colors: Array(palette[0..<6]),
        fps: Self.fps,
        codec: .hevc,
        colorProperties: [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ])
    } catch {
      throw XCTSkip("this environment cannot author an HEVC BT.2020 clip: \(error)")
    }
    guard await VideoTranscoder.needsTranscoding(source.path) else {
      try? FileManager.default.removeItem(at: source)
      throw XCTSkip("the authored clip is not detected as HDR, so nothing is transcoded")
    }
    return source
  }

  private func videoTrackRange(_ path: String) async throws -> CMTimeRange {
    let track = try await MediaInfoExtractor.loadVideoTrack(
      from: AVURLAsset(url: URL(fileURLWithPath: path)))
    return await TrackEndTrimmer.timeRange(of: track)
  }

  /// The palette color nearest to the frame shown at `seconds`.
  private func paletteIndex(_ path: String, at seconds: Double) throws -> Int {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try generator.copyCGImage(
      at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    let color = try XCTUnwrap(ThumbnailTimestampFixture.averageColor(of: image))
    return ThumbnailTimestampFixture.nearestPaletteIndex(
      color, palette: ThumbnailTimestampFixture.palette)
  }

  func testAShortClipIsTranscodedToItsWindowAndPlaysAllOfTheResult() async throws {
    let source = try await makeHdrSource()
    defer { try? FileManager.default.removeItem(at: source) }

    // Deliberately off the frame grid: 2.01 s to 3.02 s.
    let clip = VideoClip(inputPath: source.path, startUs: 2_010_000, endUs: 3_020_000)
    let trimmed = try await VideoTranscoder.transcodeClipsIfNeeded([clip])
    let whole = try await VideoTranscoder.transcodeClipsIfNeeded([
      VideoClip(inputPath: source.path)
    ])
    defer {
      VideoTranscoder.cleanupTranscodedFiles(trimmed.producedFiles + whole.producedFiles)
    }

    XCTAssertEqual(trimmed.producedFiles.count, 1)
    let rewritten = trimmed.clips[0]
    XCTAssertEqual(rewritten.inputPath, trimmed.producedFiles.first)

    // The window is the written file's own video track, whatever the encode
    // rounded it to, since the render cuts the clip hard at it. (On the
    // macOS/iOS 26 filter path the track ends exactly where it was asked to,
    // so here the two agree.)
    let track = try await videoTrackRange(rewritten.inputPath)
    let measured = VideoTranscoder.window(covering: track)
    XCTAssertEqual(rewritten.startUs, 0)
    XCTAssertEqual(rewritten.startUs, measured.startUs)
    XCTAssertEqual(rewritten.endUs, measured.endUs)
    let frameUs = Double(1_000_000) / Double(Self.fps)
    XCTAssertEqual(Double(rewritten.endUs ?? 0), 1_010_000, accuracy: frameUs)

    // It holds the window's frames: the second after 2 s, then the one after
    // 3 s at its very end. Compared against a whole-source transcode so the
    // tone mapping cannot move the answer.
    let head = try paletteIndex(rewritten.inputPath, at: 0.5)
    XCTAssertEqual(head, try paletteIndex(whole.producedFiles[0], at: 2.5))
    XCTAssertNotEqual(head, try paletteIndex(whole.producedFiles[0], at: 0.5))
    let tail = try paletteIndex(
      rewritten.inputPath, at: Double(rewritten.endUs ?? 0) / 1_000_000 - 0.001)
    XCTAssertEqual(tail, try paletteIndex(whole.producedFiles[0], at: 3.01))
  }

  func testClipsOnOneSourceShareATranscodePerWindowAndEachFileIsRemovedOnce() async throws {
    let source = try await makeHdrSource()
    let sdr = try ThumbnailTimestampFixture.makeColorVideo(
      colors: [ThumbnailTimestampFixture.palette[6]])
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: sdr)
    }

    let clips = [
      VideoClip(inputPath: source.path, startUs: 0, endUs: 1_000_000),
      VideoClip(inputPath: sdr.path, startUs: 0, endUs: 500_000),
      VideoClip(inputPath: source.path, startUs: 4_000_000, endUs: 5_000_000),
      VideoClip(inputPath: source.path, startUs: 0, endUs: 1_000_000, volume: 0.5),
    ]
    let result = try await VideoTranscoder.transcodeClipsIfNeeded(clips)

    // Two distinct windows, two files; the repeated window shares the first.
    XCTAssertEqual(result.producedFiles.count, 2)
    XCTAssertEqual(Set(result.producedFiles).count, 2)
    XCTAssertEqual(result.clips[0].inputPath, result.producedFiles[0])
    XCTAssertEqual(result.clips[2].inputPath, result.producedFiles[1])
    XCTAssertEqual(result.clips[3].inputPath, result.producedFiles[0])
    XCTAssertEqual(result.clips[3].volume, 0.5)
    // The SDR clip is not touched at all.
    XCTAssertEqual(result.clips[1].inputPath, sdr.path)
    XCTAssertEqual(result.clips[1].startUs, 0)
    XCTAssertEqual(result.clips[1].endUs, 500_000)

    for path in result.producedFiles {
      XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
    VideoTranscoder.cleanupTranscodedFiles(result.producedFiles)
    for path in result.producedFiles {
      XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: sdr.path))
  }

  func testClipsThatCoverTheSourceShareOneWholeTranscodeAndKeepTheirWindows() async throws {
    let source = try await makeHdrSource()
    defer { try? FileManager.default.removeItem(at: source) }

    let clips = [
      VideoClip(inputPath: source.path, startUs: 0, endUs: 3_000_000),
      VideoClip(inputPath: source.path, startUs: 3_000_000),
    ]
    let result = try await VideoTranscoder.transcodeClipsIfNeeded(clips)
    defer { VideoTranscoder.cleanupTranscodedFiles(result.producedFiles) }

    XCTAssertEqual(result.producedFiles.count, 1)
    XCTAssertEqual(
      result.clips.map(\.inputPath), Array(repeating: result.producedFiles[0], count: 2))
    XCTAssertEqual(result.clips[0].startUs, 0)
    XCTAssertEqual(result.clips[0].endUs, 3_000_000)
    XCTAssertEqual(result.clips[1].startUs, 3_000_000)
    XCTAssertNil(result.clips[1].endUs)
  }
}
