import AVFoundation
import CoreVideo
import XCTest

@testable import pro_video_editor

/// Picture identity is encoded in eight vertical bars, so a duplicated picture
/// cannot hide behind equal frame counts or a low average pixel difference.
final class SourceFrameTimingTests: XCTestCase {
  func testEveryFractionalRatePictureSurvivesBothExportPaths() async throws {
    let ticks = (0..<189).map { Int64($0 * 1001) }
    let source = try await makeVideo(ticks: ticks)
    defer { try? FileManager.default.removeItem(at: source) }
    let original = try await readPictures(source)
    XCTAssertEqual(original.map(\.index), Array(0..<189))
    for bitrate: Int? in [nil, 500_000] {
      let output = try await render(source, bitrate: bitrate, endUs: 6_300_000)
      defer { try? FileManager.default.removeItem(at: output) }
      let pictures = try await readPictures(output)
      XCTAssertEqual(pictures.map(\.index), original.map(\.index))
      XCTAssertEqual(pictures.count, original.count)
      for (actual, expected) in zip(pictures, original) {
        XCTAssertEqual(actual.seconds, expected.seconds, accuracy: 0.002)
      }
    }
  }

  func testTrimmedVariableRatePicturesKeepTheirSourceTimes() async throws {
    let ticks: [Int64] = (0..<202).map { index in
      let regular = Int64(index) * 1001
      let variation = Int64(index % 3) * 90
      return regular + variation
    }
    let source = try await makeVideo(ticks: ticks)
    defer { try? FileManager.default.removeItem(at: source) }
    let startUs = ticks[6] * 100 / 3
    let endUs = ticks[195] * 100 / 3
    let output = try await render(source, startUs: startUs, endUs: endUs)
    defer { try? FileManager.default.removeItem(at: output) }
    let pictures = try await readPictures(output)
    XCTAssertEqual(pictures.map(\.index), Array(6..<195))
    for (actual, tick) in zip(pictures, ticks[6..<195]) {
      XCTAssertEqual(actual.seconds, Double(tick - ticks[6]) / 30_000, accuracy: 0.002)
    }
  }

  /// A trim read back from a frame time is rounded or truncated to whole
  /// microseconds, so it misses its picture's start by a fraction of one. It
  /// still cuts on that picture, at 30 fps and 29.97 fps, on the source's
  /// timing and on the fixed clock.
  func testTrimsAFractionOfAMicrosecondOffAPictureCutOnIt() async throws {
    for (frameTicks, sourceTiming) in [(1000, [true, false]), (1001, [true])] {
      let ticks = (0..<120).map { Int64($0 * frameTicks) }
      let source = try await makeVideo(ticks: ticks)
      defer { try? FileManager.default.removeItem(at: source) }
      // Pictures 10 and 86 both start between two microseconds.
      for preserveSourceFrameTiming in sourceTiming {
        for startRoundsUp in [false, true] {
          for endRoundsUp in [false, true] {
            let output = try await render(
              source,
              startUs: microseconds(ticks[10], roundingUp: startRoundsUp),
              endUs: microseconds(ticks[86], roundingUp: endRoundsUp),
              preserveSourceFrameTiming: preserveSourceFrameTiming)
            defer { try? FileManager.default.removeItem(at: output) }
            let pictures = try await readPictures(output)
            let label =
              "\(frameTicks) ticks, start \(startRoundsUp ? "up" : "down"), "
              + "end \(endRoundsUp ? "up" : "down"), source timing \(preserveSourceFrameTiming)"
            XCTAssertEqual(pictures.map(\.index), Array(10..<86), label)
            for (actual, tick) in zip(pictures, ticks[10..<86]) {
              XCTAssertEqual(
                actual.seconds, Double(tick - ticks[10]) / 30_000, accuracy: 0.002, label)
            }
          }
        }
      }
    }
  }

  /// The pre-transcode is not told about the mode: its filter composition
  /// takes the source track's timing on its own, which this pins down.
  func testPreTranscodeKeepsFractionalRatePictures() async throws {
    let ticks = (0..<189).map { Int64($0 * 1001) }
    let source = try await makeVideo(ticks: ticks)
    defer { try? FileManager.default.removeItem(at: source) }
    let result = await VideoTranscoder.transcodeToH264(source.path)
    switch result {
    case .success(let path, _):
      let output = URL(fileURLWithPath: path)
      defer { try? FileManager.default.removeItem(at: output) }
      let pictures = try await readPictures(output)
      XCTAssertEqual(pictures.map(\.index), Array(0..<189))
      for (actual, tick) in zip(pictures, ticks) {
        XCTAssertEqual(actual.seconds, Double(tick) / 30_000, accuracy: 0.002)
      }
    case .error(let error):
      throw error
    }
  }

  func testUnsupportedSourceTimingCombinationsFailBeforeReadingMedia() async throws {
    let clip: [String: Any] = ["inputPath": "/does/not/exist.mp4"]
    let invalid: [[String: Any]] = [
      ["videoClips": [clip, clip]],
      ["videoClips": [clip], "maxFrameRate": 30],
      ["composition": ["layers": [["clips": [clip]]]]],
      ["videoClips": [clip.merging(["reverseVideo": true]) { _, new in new }]],
      [
        "videoClips": [
          clip.merging([
            "transition": ["type": "dissolve", "durationUs": 500_000]
          ]) { _, new in new }
        ]
      ],
      ["videoClips": [clip.merging(["playbackSpeed": 2.0]) { _, new in new }]],
      ["videoClips": [clip], "playbackSpeed": 0.5],
      [
        "videoClips": [
          clip.merging([
            "speedRamp": [["start": 0.0, "end": 1.0, "speed": 2.0]]
          ]) { _, new in new }
        ]
      ],
    ]
    for var arguments in invalid {
      arguments["preserveSourceFrameTiming"] = true
      let config = try XCTUnwrap(RenderConfig.fromArguments(arguments))
      let settled = expectation(description: "unsupported timing fails before media access")
      settled.assertForOverFulfill = true
      var failure: NSError?
      RenderVideo.render(
        config: config, onProgress: { _ in },
        onComplete: { _ in
          XCTFail("unsupported render succeeded")
          settled.fulfill()
        },
        onError: {
          failure = $0 as NSError
          settled.fulfill()
        })
      await fulfillment(of: [settled], timeout: 10)
      XCTAssertEqual(failure?.domain, "SourceFrameTiming")
      XCTAssertEqual(failure?.code, 1)
    }
  }

  /// `tick` of a 30000 timescale in whole microseconds, rounded down or up.
  private func microseconds(_ tick: Int64, roundingUp: Bool) -> Int64 {
    (tick * 100 + (roundingUp ? 2 : 0)) / 3
  }

  private func render(
    _ source: URL, bitrate: Int? = nil, startUs: Int64? = nil, endUs: Int64? = nil,
    preserveSourceFrameTiming: Bool = true
  ) async throws -> URL {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("pve_source_timing_\(UUID().uuidString).mp4")
    var clip: [String: Any] = [
      "inputPath": source.path,
      "stabilization": ["timesUs": [0, 7_000_000], "values": [0, 0, 0, 1.02, 0, 0, 0, 1.02]],
    ]
    if let startUs { clip["startUs"] = startUs }
    if let endUs { clip["endUs"] = endUs }
    var arguments: [String: Any] = [
      "videoClips": [clip], "outputPath": output.path,
      "outputFormat": "mp4", "preserveSourceFrameTiming": preserveSourceFrameTiming,
    ]
    if let bitrate { arguments["bitrate"] = bitrate }
    let config = try XCTUnwrap(RenderConfig.fromArguments(arguments))
    let settled = expectation(description: "source-timed render settles")
    settled.assertForOverFulfill = true
    var failure: Error?
    RenderVideo.render(
      config: config, onProgress: { _ in },
      onComplete: { _ in settled.fulfill() },
      onError: {
        failure = $0
        settled.fulfill()
      })
    await fulfillment(of: [settled], timeout: 120)
    if let failure { throw failure }
    return output
  }

  private func makeVideo(ticks: [Int64]) async throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pve_indexed_\(UUID().uuidString).mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 128, AVVideoHeightKey: 64,
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1],
      ])
    input.mediaTimeScale = 30_000
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 64,
      ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for (index, tick) in ticks.enumerated() {
      var optionalBuffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(
        kCFAllocatorDefault, 128, 64, kCVPixelFormatType_32BGRA, nil, &optionalBuffer)
      XCTAssertEqual(status, kCVReturnSuccess)
      let buffer = try XCTUnwrap(optionalBuffer)
      CVPixelBufferLockBaseAddress(buffer, [])
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        .assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      for y in 0..<64 {
        for x in 0..<128 {
          let value: UInt8 = index & (1 << (x / 16)) == 0 ? 16 : 235
          let pixel = base + y * stride + x * 4
          pixel[0] = value
          pixel[1] = value
          pixel[2] = value
          pixel[3] = 255
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      let deadline = Date().addingTimeInterval(10)
      while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
        try await Task.sleep(nanoseconds: 500_000)
      }
      XCTAssertTrue(input.isReadyForMoreMediaData)
      XCTAssertTrue(
        adaptor.append(buffer, withPresentationTime: CMTime(value: tick, timescale: 30_000)))
    }
    writer.endSession(atSourceTime: CMTime(value: ticks.last! + 1001, timescale: 30_000))
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    if let error = writer.error { throw error }
    return url
  }

  private func readPictures(_ url: URL) async throws -> [(seconds: Double, index: Int)] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ])
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var pictures: [(Double, Int)] = []
    while let sample = output.copyNextSampleBuffer() {
      let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        .assumingMemoryBound(to: UInt8.self)
      let row = CVPixelBufferGetHeight(buffer) / 2 * CVPixelBufferGetBytesPerRow(buffer)
      let width = CVPixelBufferGetWidth(buffer)
      var index = 0
      for bit in 0..<8 where base[row + (width * (2 * bit + 1) / 16) * 4 + 1] > 128 {
        index |= 1 << bit
      }
      CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
      pictures.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, index))
    }
    XCTAssertEqual(reader.status, .completed)
    return pictures
  }
}

final class PictureStartSnappingTests: XCTestCase {
  private let unedited = [
    CMTimeMapping(
      source: CMTimeRange(start: .zero, duration: CMTime(value: 120_000, timescale: 30_000)),
      target: CMTimeRange(start: .zero, duration: CMTime(value: 120_000, timescale: 30_000)))
  ]

  private func snapped(_ us: Int64, edits: [CMTimeMapping]) -> CMTime {
    PictureStartSnapping.snapped(
      microseconds(us), mediaTimeScale: 30_000, edits: edits)
  }

  private func microseconds(_ us: Int64) -> CMTime {
    CMTime(value: us, timescale: 1_000_000)
  }

  func testAMicrosecondEitherSideOfAPictureMeansThatPicture() {
    // Picture 86 of a 30 fps clip starts at 2866666.67 µs.
    let picture = CMTime(value: 86_000, timescale: 30_000)
    XCTAssertEqual(snapped(2_866_666, edits: unedited), picture)
    XCTAssertEqual(snapped(2_866_667, edits: unedited), picture)
    XCTAssertEqual(snapped(2_866_668, edits: unedited), microseconds(2_866_668))
    XCTAssertEqual(snapped(2_866_665, edits: unedited), microseconds(2_866_665))
  }

  func testATimeOnAPictureStaysWhereItIs() {
    XCTAssertEqual(
      snapped(3_000_000, edits: unedited), CMTime(value: 90_000, timescale: 30_000))
    XCTAssertEqual(snapped(0, edits: unedited), .zero)
  }

  func testAnEditThatShiftsTheMediaIsFollowed() {
    // A B-frame delay of two pictures cut off by the edit list, and an empty
    // edit of 21 ms in the movie's timescale before it.
    let delay = CMTime(value: 2_000, timescale: 30_000)
    let empty = CMTime(value: 21, timescale: 1_000)
    let duration = CMTime(value: 118_000, timescale: 30_000)
    let edits = [
      CMTimeMapping(
        source: CMTimeRange(start: delay, duration: duration),
        target: CMTimeRange(start: empty, duration: duration))
    ]
    // Picture 12 starts 400000 µs into the media. The edit drops its first
    // two pictures and plays the rest 21 ms late: 354333.33 µs on the track.
    let picture = CMTimeAdd(empty, CMTime(value: 10_000, timescale: 30_000))
    XCTAssertEqual(snapped(354_333, edits: edits), picture)
    XCTAssertEqual(snapped(354_334, edits: edits), picture)
  }

  func testAnEditAtAnotherRateIsLeftAlone() {
    let edits = [
      CMTimeMapping(
        source: CMTimeRange(start: .zero, duration: CMTime(value: 120_000, timescale: 30_000)),
        target: CMTimeRange(start: .zero, duration: CMTime(value: 60_000, timescale: 30_000)))
    ]
    XCTAssertEqual(snapped(1_433_333, edits: edits), microseconds(1_433_333))
  }

  func testATimeOutsideEveryEditIsLeftAlone() {
    XCTAssertEqual(snapped(5_000_001, edits: unedited), microseconds(5_000_001))
    XCTAssertEqual(snapped(1_433_333, edits: []), microseconds(1_433_333))
  }
}
