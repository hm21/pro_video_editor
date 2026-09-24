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

  func testAWindowIsEncodedWithATailAsFarAsTheSourceRuns() {
    let tail = VideoTranscoder.windowTailUs
    XCTAssertEqual(
      VideoTranscoder.encodedRange(
        for: Range(startUs: 2 * second, endUs: 4 * second), sourceDurationUs: 10 * second),
      Range(startUs: 2 * second, endUs: 4 * second + tail))
    XCTAssertEqual(
      VideoTranscoder.encodedRange(
        for: Range(startUs: 8 * second, endUs: 10 * second - tail / 2),
        sourceDurationUs: 10 * second),
      Range(startUs: 8 * second, endUs: 10 * second))
    // Without a known duration there is no tail, and the window stays whole.
    XCTAssertEqual(
      VideoTranscoder.encodedRange(
        for: Range(startUs: 2 * second, endUs: 4 * second), sourceDurationUs: 0),
      Range(startUs: 2 * second, endUs: 4 * second))
  }

  func testATrimmedClipPlaysItsWindowsLengthAndStopsBeforeTheTail() {
    let window = Range(startUs: 2_010_000, endUs: 4_020_000)
    let longer = CMTimeRange(
      start: .zero, duration: CMTime(value: 2_510_000, timescale: 1_000_000))
    XCTAssertEqual(
      VideoTranscoder.clipWindow(playing: window, writtenTrack: longer),
      Range(startUs: 0, endUs: 2_010_000))
    // At the end of the source nothing follows the window, and a track that
    // ends sooner ends it, rounded outwards: 31 frames at 29.97 fps.
    let shorter = CMTimeRange(start: .zero, duration: CMTime(value: 31 * 1001, timescale: 30_000))
    XCTAssertEqual(
      VideoTranscoder.clipWindow(playing: window, writtenTrack: shorter),
      Range(startUs: 0, endUs: 1_034_367))
  }
}

// MARK: - Cadence of a trimmed pre-transcode (#210)

/// The frame rate the render uses for a clip cut down to its window, measured
/// from the frames of the shorter file: its `nominalFrameRate` counts a sliver
/// of a frame as a whole one.
final class TypicalFrameRateTests: XCTestCase {

  /// `count` frames at `fps` on `timescale`, each rounded to its nearest tick
  /// the way a muxer stores them.
  private func frames(_ count: Int, fps: Double, timescale: Int32) -> [CMTime] {
    (0..<count).map { index in
      let start = (Double(index) * Double(timescale) / fps).rounded()
      let end = (Double(index + 1) * Double(timescale) / fps).rounded()
      return CMTime(value: CMTimeValue(end - start), timescale: timescale)
    }
  }

  private func ticks(_ values: [CMTimeValue], _ timescale: Int32) -> [CMTime] {
    values.map { CMTime(value: $0, timescale: timescale) }
  }

  private func rate(_ durations: [CMTime]) -> Float? {
    VideoTranscoder.typicalFrameRate(ofFrameDurations: durations)
  }

  func testAPartialFirstAndLastFrameDoNotCount() {
    // A 0.1 ms sliver of the frame before the window, then a last frame the
    // file cuts short: `nominalFrameRate` reads ~33 fps for 0.4 s of this.
    let durations = ticks([9], 90_000) + frames(11, fps: 30, timescale: 90_000)
      + ticks([1_200], 90_000)
    XCTAssertEqual(rate(durations), 30)
  }

  func testTheOnlyWholeFrameDecidesBetweenTwoPartialOnes() {
    // 25 fps: a sliver, a whole frame, and a last frame cut in half. Their
    // median is the half frame, which reads 50 fps.
    XCTAssertEqual(rate(ticks([900, 3_600, 1_800], 90_000)), 25)
  }

  func testACoarseTimescaleIsAveragedBackToTheCadence() {
    // Every frame of 60 fps on a 1000 timescale lasts 16 or 17 ms; the median
    // alone reads 58.8, which the render would cut down to 58 fps.
    XCTAssertEqual(rate(frames(55, fps: 60, timescale: 1_000)), 60)
    // 8 or 9 ms at 120 fps, whose median reads 125.
    XCTAssertEqual(rate(frames(109, fps: 120, timescale: 1_000)), 120)
    XCTAssertEqual(rate(frames(28, fps: 30, timescale: 1_000)), 30)
  }

  func testAFractionalRateStaysFractional() {
    // 59.94 fps is 1001 ticks a frame on 60 000: no rounding to undo, so it
    // is not taken for 60.
    let ntsc = 60_000.0 / 1_001.0
    let window = ticks([66], 60_000) + frames(53, fps: ntsc, timescale: 60_000)
    XCTAssertEqual(rate(window), Float(ntsc))
    XCTAssertEqual(
      rate(frames(28, fps: ntsc / 2, timescale: 30_000)), Float(30_000.0 / 1_001.0))
  }

  func testJitteredTimestampsSnapToTheWholeRate() {
    // A phone's capture timestamps wander by a few ticks around 3000.
    let jittered: [CMTimeValue] = [
      14, 3_000, 3_001, 2_999, 3_000, 3_007, 2_993, 3_000, 3_001, 2_999, 3_004, 2_998, 3_000,
    ]
    XCTAssertEqual(rate(ticks(jittered, 90_000)), 30)
  }

  func testTheGapOfADroppedFrameIsLeftOut() {
    // 60 fps with every seventh frame dropped: the average is 51.4 fps.
    var values: [CMTimeValue] = []
    for index in 0..<48 { values.append(index % 7 == 3 ? 20 : 10) }
    XCTAssertEqual(rate(ticks(values, 600)), 60)
  }

  func testTooFewFramesToTellAreNotMeasured() {
    XCTAssertNil(rate([]))
    XCTAssertNil(rate(ticks([1_500], 90_000)))
    // Either could be a partial frame.
    XCTAssertNil(rate(ticks([1_500, 3_000], 90_000)))
    // One whole frame of 16 ms: anything from 59 to 66 fps rounds to it.
    XCTAssertNil(rate(ticks([17, 16, 16], 1_000)))
    // One whole frame on a fine timescale pins the rate down.
    XCTAssertEqual(rate(ticks([9, 1_500, 700], 90_000)), 60)
    XCTAssertNil(rate(ticks([9, 0, 700], 90_000)))
  }
}

// MARK: - Trimmed pre-transcode on a real encode (#192)

/// The pre-transcode end to end on an HDR-tagged clip whose every second is a
/// different color, so a window can be recognised in the file it produced.
final class TrimmedPreTranscodeTests: XCTestCase {
  private static let fps: Int32 = 30

  /// Six seconds, one palette color each.
  private func makeHdrSource(
    fps: Int32 = TrimmedPreTranscodeTests.fps, timescale: CMTimeScale? = nil
  ) async throws -> URL {
    let palette = ThumbnailTimestampFixture.palette
    let source: URL
    do {
      // HEVC tagged BT.2020 is what `needsTranscodingForEffects` keys on; the
      // pixels themselves stay 8-bit.
      source = try ThumbnailTimestampFixture.makeColorVideo(
        colors: Array(palette[0..<6]),
        fps: fps,
        codec: .hevc,
        colorProperties: [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ],
        timescale: timescale)
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

  func testAShortClipIsTranscodedToItsWindowAndPlaysExactlyItsLength() async throws {
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

    // The file starts at the window and runs past it, so the clip plays
    // exactly the window's length of it; the tail after it is encoded only
    // so the file's audio does not end inside the window.
    let track = try await videoTrackRange(rewritten.inputPath)
    let measured = VideoTranscoder.window(covering: track)
    XCTAssertEqual(rewritten.startUs, 0)
    XCTAssertEqual(rewritten.startUs, measured.startUs)
    XCTAssertEqual(rewritten.endUs, 1_010_000)
    XCTAssertGreaterThan(measured.endUs, 1_010_000)
    // A short file's `nominalFrameRate` misreads its cadence, so the clip
    // carries the one measured from its frames: exactly the fixture's 30.
    XCTAssertEqual(rewritten.frameRateOverride, Float(Self.fps))
    XCTAssertNil(whole.clips[0].frameRateOverride)

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

  func testAWindowAtTheEndOfTheSourceEndsWithTheWrittenTrack() async throws {
    let source = try await makeHdrSource()
    defer { try? FileManager.default.removeItem(at: source) }

    // 4.5 s to the end of the 6 s source: no tail follows it to encode.
    let result = try await VideoTranscoder.transcodeClipsIfNeeded([
      VideoClip(inputPath: source.path, startUs: 4_500_000)
    ])
    defer { VideoTranscoder.cleanupTranscodedFiles(result.producedFiles) }

    XCTAssertEqual(result.producedFiles.count, 1)
    let rewritten = result.clips[0]
    let measured = VideoTranscoder.window(
      covering: try await videoTrackRange(rewritten.inputPath))
    XCTAssertEqual(rewritten.startUs, measured.startUs)
    XCTAssertEqual(rewritten.endUs, measured.endUs)
    let frameUs = Double(1_000_000) / Double(Self.fps)
    XCTAssertEqual(Double(rewritten.endUs ?? 0), 1_500_000, accuracy: frameUs)
  }

  /// Renders `startUs..<endUs` of `source` on its own and counts the frames
  /// of the result and the length of its video track.
  private func renderWindow(of source: URL, startUs: Int64, endUs: Int64) async throws
    -> (frames: Int, seconds: Double)
  {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("pve_trim_cadence_\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    let config = try XCTUnwrap(
      RenderConfig.fromArguments([
        "videoClips": [
          [
            "inputPath": source.path,
            "startUs": NSNumber(value: startUs),
            "endUs": NSNumber(value: endUs),
          ]
        ],
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

    let asset = AVURLAsset(url: output)
    let track = try await MediaInfoExtractor.loadVideoTrack(from: asset)
    let reader = try AVAssetReader(asset: asset)
    let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(samples)
    XCTAssertTrue(reader.startReading())
    var frames = 0
    while let buffer = samples.copyNextSampleBuffer() {
      if CMSampleBufferGetNumSamples(buffer) > 0 { frames += 1 }
    }
    let seconds = await TrackEndTrimmer.timeRange(of: track).duration.seconds
    return (frames, seconds)
  }

  func testARenderOfAShortTrimmedWindowKeepsTheSourceCadence() async throws {
    // A phone recording's timescale; the fixture's default of 30 would snap
    // the window below onto the frame boundary.
    let source = try await makeHdrSource(timescale: 90_000)
    defer { try? FileManager.default.removeItem(at: source) }

    // 0.4 s starting a tenth of a millisecond before a frame boundary, as
    // phone footage does: the trimmed file opens on a 0.1 ms sliver of the
    // previous frame, and AVFoundation reports ~33 fps for it. Rendering at
    // that rate instead of the footage's 30 fps packed extra frames into the
    // window and re-timed every one of them.
    let rendered = try await renderWindow(of: source, startUs: 999_900, endUs: 1_399_900)
    XCTAssertEqual(rendered.frames, 12, "0.4 s at the source's 30 fps")
    XCTAssertEqual(rendered.seconds, 0.4, accuracy: 0.001)
  }

  func testARenderOfAWindowOnACoarseTimescaleKeepsTheSourceCadence() async throws {
    // 60 fps rounded onto a 1000 timescale, as a remux from Matroska stores
    // it: every frame lasts 16 or 17 ms. Their median alone reads 58.8 fps,
    // which the render cut down to 58 and so dropped two frames a second.
    let source = try await makeHdrSource(fps: 60, timescale: 1_000)
    defer { try? FileManager.default.removeItem(at: source) }

    let trimmed = try await VideoTranscoder.transcodeClipsIfNeeded([
      VideoClip(inputPath: source.path, startUs: 1_000_000, endUs: 2_000_000),
      // The last 30 ms: a partial frame and the last one, and no tail to
      // encode after them. Too few to time, so the clip takes the source's
      // rate rather than whatever their durations suggest, which would set
      // the frame rate of the whole export.
      VideoClip(inputPath: source.path, startUs: 5_970_000),
    ])
    VideoTranscoder.cleanupTranscodedFiles(trimmed.producedFiles)
    XCTAssertEqual(trimmed.producedFiles.count, 2)
    XCTAssertEqual(trimmed.clips[0].frameRateOverride, 60)
    XCTAssertEqual(Double(trimmed.clips[1].frameRateOverride ?? 0), 60, accuracy: 0.5)

    let rendered = try await renderWindow(of: source, startUs: 1_000_000, endUs: 2_000_000)
    XCTAssertEqual(rendered.frames, 60, "1 s at the source's 60 fps")
    XCTAssertEqual(rendered.seconds, 1, accuracy: 0.001)
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
