import AVFoundation
import Cocoa
import CoreGraphics
import CoreMedia
import FlutterMacOS
import ImageIO
import XCTest


@testable import pro_video_editor

// This demonstrates a simple unit test of the Swift portion of this plugin's implementation.
//
// See https://developer.apple.com/documentation/xctest for more information about using XCTest.

class RunnerTests: XCTestCase {

  func testGetPlatformVersion() {
    let plugin = ProVideoEditorPlugin()

    let call = FlutterMethodCall(methodName: "getPlatformVersion", arguments: [])

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertEqual(result as! String,
                     "macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  // MARK: - Slide animation geometry

  // Frame 1000×500, a small layer (200×100) centered at (400, 200) in
  // Core Graphics (Y bottom-up) coordinates.
  private let slideFrame = CGRect(x: 0, y: 0, width: 1000, height: 500)
  private let slideOverlay = CGRect(x: 400, y: 200, width: 200, height: 100)

  func testSlideMovesLayerFullyOutAtInvPOne() {
    let left = slideOffset(
      direction: "left", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let right = slideOffset(
      direction: "right", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let top = slideOffset(
      direction: "top", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let bottom = slideOffset(
      direction: "bottom", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)

    // Edge-aware distance, not the old overlay-size-relative one.
    XCTAssertEqual(left.x, -600, accuracy: 1e-6)
    XCTAssertEqual(right.x, 600, accuracy: 1e-6)
    XCTAssertEqual(top.y, 300, accuracy: 1e-6)
    XCTAssertEqual(bottom.y, -300, accuracy: 1e-6)
  }

  func testSlideTrailingEdgeLandsOnFrameEdge() {
    let left = slideOffset(
      direction: "left", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let right = slideOffset(
      direction: "right", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let top = slideOffset(
      direction: "top", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let bottom = slideOffset(
      direction: "bottom", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)

    XCTAssertEqual(slideOverlay.maxX + left.x, slideFrame.minX, accuracy: 1e-6)
    XCTAssertEqual(slideOverlay.minX + right.x, slideFrame.maxX, accuracy: 1e-6)
    XCTAssertEqual(slideOverlay.minY + top.y, slideFrame.maxY, accuracy: 1e-6)
    XCTAssertEqual(slideOverlay.maxY + bottom.y, slideFrame.minY, accuracy: 1e-6)
  }

  func testSlideIsZeroAtRestAndLinearInInvP() {
    let rest = slideOffset(
      direction: "left", invP: 0, overlayExtent: slideOverlay, frameExtent: slideFrame)
    XCTAssertEqual(rest.x, 0, accuracy: 1e-6)
    XCTAssertEqual(rest.y, 0, accuracy: 1e-6)

    let full = slideOffset(
      direction: "left", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let half = slideOffset(
      direction: "left", invP: 0.5, overlayExtent: slideOverlay, frameExtent: slideFrame)
    XCTAssertEqual(half.x, full.x / 2, accuracy: 1e-6)
  }

  func testSlideUnknownDirectionProducesNoOffset() {
    let off = slideOffset(
      direction: "diagonal", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    XCTAssertEqual(off.x, 0, accuracy: 1e-6)
    XCTAssertEqual(off.y, 0, accuracy: 1e-6)
  }

  // MARK: - Engine-detach result delivery

  // Before detach a captured FlutterResult delivers normally.
  func testDeliverResultInvokesClosureBeforeDetach() {
    let plugin = ProVideoEditorPlugin()

    var deliveredCount = 0
    var deliveredValue: Any?
    plugin.deliverResult({ value in
      deliveredCount += 1
      deliveredValue = value
    }, "payload")

    XCTAssertEqual(deliveredCount, 1)
    XCTAssertEqual(deliveredValue as? String, "payload")
  }

  // Regression guard for the `else`-after-detach hole: once the engine has been
  // torn down, a late async delivery must be a terminal no-op so it never
  // messages a no-longer-running FlutterEngine.
  func testDeliverResultIsNoOpAfterDetach() {
    let plugin = ProVideoEditorPlugin()

    plugin.tearDownForEngineDetach()

    var deliveredCount = 0
    plugin.deliverResult({ _ in
      deliveredCount += 1
    }, "payload")

    XCTAssertEqual(deliveredCount, 0)
  }

  // MARK: - Thumbnail timestamp alignment (concurrent-callback regression)

  // A synthetic video is authored with one distinct solid color per second.
  // Thumbnails are then requested for many timestamps, in shuffled order, and
  // every returned frame must decode to the color of the second it was
  // requested for. This exercises the path where
  // `generateCGImagesAsynchronously(forTimes:)` (and the ordered async
  // sequence) delivers callbacks concurrently / out of order — the regression
  // that previously mapped frames to the wrong timestamps or never completed.
  //
  // The result must (a) always arrive (no hang), (b) equal the requested count,
  // and (c) map index-for-index to the requested timestamps with no reordering,
  // dropped, or duplicated frames — verified across a stress loop.
  func testThumbnailsAlignToRequestedTimestampsUnderConcurrency() throws {
    let palette = ThumbnailTimestampFixture.palette
    let videoURL = try ThumbnailTimestampFixture.makeColorVideo(colors: palette)
    defer { try? FileManager.default.removeItem(at: videoURL) }

    // Three sub-second offsets per color band, well away from band edges so the
    // decoded frame is unambiguously inside a single color.
    var entries: [(us: Int64, colorIndex: Int)] = []
    for second in 0..<palette.count {
      for frac in [0.3, 0.5, 0.7] {
        let seconds = Double(second) + frac
        entries.append((Int64((seconds * 1_000_000).rounded()), second))
      }
    }

    let iterations = 12
    for iteration in 0..<iterations {
      // Shuffle so the requested order differs from the natural order; the
      // returned array must still line up with the request positions.
      let shuffled = entries.shuffled()
      let timestampsUs = shuffled.map { $0.us }
      let expectedColorIndex = shuffled.map { $0.colorIndex }

      let config = ThumbnailConfig(
        id: "concurrency-\(iteration)",
        inputPath: videoURL.path,
        fileExtension: "mp4",
        boxFit: "contain",
        outputFormat: "png",
        jpegQuality: 100,
        outputWidth: 80,
        outputHeight: 45,
        timestampsUs: timestampsUs,
        maxOutputFrames: nil,
        lastFrameTolerance: false
      )

      let completed = expectation(description: "onComplete fires (iteration \(iteration))")
      completed.assertForOverFulfill = true
      var received: [Data]?
      var receivedError: Error?

      ThumbnailGenerator.getThumbnails(
        config: config,
        onProgress: { _ in },
        onComplete: { data in
          received = data
          completed.fulfill()
        },
        onError: { error in
          receivedError = error
          completed.fulfill()
        }
      )

      // A timeout here is the guard against the wedge: a lost completion count
      // used to leave the continuation unresumed forever.
      wait(for: [completed], timeout: 30)

      XCTAssertNil(receivedError, "iteration \(iteration): unexpected error")
      guard let result = received else {
        XCTFail("iteration \(iteration): no result delivered")
        return
      }

      XCTAssertEqual(
        result.count, timestampsUs.count,
        "iteration \(iteration): result count must equal requested count")

      for i in 0..<min(result.count, expectedColorIndex.count) {
        XCTAssertFalse(
          result[i].isEmpty,
          "iteration \(iteration): frame \(i) is unexpectedly empty")

        guard let color = ThumbnailTimestampFixture.decodedColor(result[i]) else {
          XCTFail("iteration \(iteration): frame \(i) could not be decoded")
          continue
        }

        let classified = ThumbnailTimestampFixture.nearestPaletteIndex(color, palette: palette)
        XCTAssertEqual(
          classified, expectedColorIndex[i],
          "iteration \(iteration): frame \(i) (t=\(timestampsUs[i])us) decoded to "
            + "color band \(classified) but timestamp belongs to band \(expectedColorIndex[i])")
      }
    }
  }

  // A single failed/out-of-range frame must not drop the others or shift them:
  // the result stays index-aligned, the bad slot is an empty `Data()`, and the
  // call still completes.
  func testThumbnailsRepresentFailedFramePositionally() throws {
    let palette = ThumbnailTimestampFixture.palette
    let videoURL = try ThumbnailTimestampFixture.makeColorVideo(colors: palette)
    defer { try? FileManager.default.removeItem(at: videoURL) }

    // Middle timestamp is far past the end of the video, so that frame fails
    // while the surrounding ones succeed.
    let good0 = Int64(0.5 * 1_000_000)
    let bad = Int64(9_999 * 1_000_000)
    let good1 = Int64(1.5 * 1_000_000)
    let timestampsUs = [good0, bad, good1]

    let config = ThumbnailConfig(
      id: "positional",
      inputPath: videoURL.path,
      fileExtension: "mp4",
      boxFit: "contain",
      outputFormat: "png",
      jpegQuality: 100,
      outputWidth: 80,
      outputHeight: 45,
      timestampsUs: timestampsUs,
      maxOutputFrames: nil,
      lastFrameTolerance: false
    )

    let completed = expectation(description: "onComplete fires")
    var received: [Data]?
    ThumbnailGenerator.getThumbnails(
      config: config,
      onProgress: { _ in },
      onComplete: { data in
        received = data
        completed.fulfill()
      },
      onError: { _ in }
    )
    wait(for: [completed], timeout: 30)

    guard let result = received else {
      XCTFail("no result delivered")
      return
    }

    XCTAssertEqual(result.count, 3, "result must stay the length of the request")
    XCTAssertFalse(result[0].isEmpty, "first frame should succeed")
    XCTAssertFalse(result[2].isEmpty, "third frame should succeed")

    if let c0 = ThumbnailTimestampFixture.decodedColor(result[0]) {
      XCTAssertEqual(
        ThumbnailTimestampFixture.nearestPaletteIndex(c0, palette: palette), 0)
    } else {
      XCTFail("could not decode frame 0")
    }
    if let c2 = ThumbnailTimestampFixture.decodedColor(result[2]) {
      XCTAssertEqual(
        ThumbnailTimestampFixture.nearestPaletteIndex(c2, palette: palette), 1)
    } else {
      XCTFail("could not decode frame 2")
    }
  }

  // Drives the legacy `generateCGImagesAsynchronously` path (lock +
  // requestedTime→index resolution) directly. Modern OS versions route
  // production through the ordered async sequence, so this is the only coverage
  // for the concurrent-callback code — the exact code the wedge lived in.
  func testConcurrentPathAlignsFramesToTimestamps() throws {
    let palette = ThumbnailTimestampFixture.palette
    let videoURL = try ThumbnailTimestampFixture.makeColorVideo(colors: palette)
    defer { try? FileManager.default.removeItem(at: videoURL) }

    var entries: [(us: Int64, colorIndex: Int)] = []
    for second in 0..<palette.count {
      for frac in [0.3, 0.5, 0.7] {
        let seconds = Double(second) + frac
        entries.append((Int64((seconds * 1_000_000).rounded()), second))
      }
    }

    for iteration in 0..<8 {
      let shuffled = entries.shuffled()
      let timestampsUs = shuffled.map { $0.us }
      let expectedColorIndex = shuffled.map { $0.colorIndex }

      let config = ThumbnailConfig(
        id: "concurrent-\(iteration)",
        inputPath: videoURL.path,
        fileExtension: "mp4",
        boxFit: "contain",
        outputFormat: "png",
        jpegQuality: 100,
        outputWidth: 80,
        outputHeight: 45,
        timestampsUs: timestampsUs,
        maxOutputFrames: nil,
        lastFrameTolerance: false
      )

      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero

      let times = timestampsUs.map {
        NSValue(time: CMTime(value: $0, timescale: 1_000_000))
      }

      let done = expectation(description: "concurrent path completes (iteration \(iteration))")
      Task {
        let result = await ThumbnailGenerator.generateThumbnailDataConcurrent(
          generator: generator,
          times: times,
          config: config,
          onProgress: { _ in }
        )

        XCTAssertEqual(
          result.count, timestampsUs.count,
          "iteration \(iteration): concurrent path result count")

        for i in 0..<min(result.count, expectedColorIndex.count) {
          XCTAssertFalse(
            result[i].isEmpty,
            "iteration \(iteration): concurrent frame \(i) is empty")
          if let color = ThumbnailTimestampFixture.decodedColor(result[i]) {
            XCTAssertEqual(
              ThumbnailTimestampFixture.nearestPaletteIndex(color, palette: palette),
              expectedColorIndex[i],
              "iteration \(iteration): concurrent frame \(i) misaligned")
          } else {
            XCTFail("iteration \(iteration): concurrent frame \(i) could not decode")
          }
        }
        done.fulfill()
      }

      // Times out (fails) rather than hanging forever if the continuation is
      // never resumed — the original wedge.
      wait(for: [done], timeout: 30)
    }
  }

}

// MARK: - Thumbnail timestamp test fixtures

/// Helpers for authoring a color-coded test video and reading colors back out
/// of generated thumbnails. Shared by the iOS and macOS RunnerTests.
enum ThumbnailTimestampFixture {

  typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

  /// Eight solid colors, each pair separated by a large RGB distance so a
  /// nearest-color classification survives the RGB→YUV→RGB round trip of H.264
  /// without ever misclassifying which band a frame came from.
  static let palette: [RGB] = [
    (215, 40, 40),
    (40, 215, 40),
    (40, 40, 215),
    (215, 215, 40),
    (215, 40, 215),
    (40, 215, 215),
    (215, 215, 215),
    (40, 40, 40),
  ]

  /// Authors an H.264 `.mp4` where second `i` is entirely `colors[i]`.
  static func makeColorVideo(
    colors: [RGB],
    fps: Int32 = 30,
    size: CGSize = CGSize(width: 160, height: 90)
  ) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pve_thumb_\(UUID().uuidString).mp4")

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
      ]
    )

    guard writer.canAdd(input) else {
      throw NSError(domain: "ThumbnailTimestampFixture", code: 1)
    }
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let framesPerColor = Int(fps)
    var frameIndex = 0
    for color in colors {
      let buffer = try makePixelBuffer(color: color, size: size)
      for _ in 0..<framesPerColor {
        while !input.isReadyForMoreMediaData {
          usleep(500)
        }
        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
        adaptor.append(buffer, withPresentationTime: pts)
        frameIndex += 1
      }
    }

    input.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    finished.wait()

    guard writer.status == .completed else {
      throw writer.error
        ?? NSError(domain: "ThumbnailTimestampFixture", code: 2)
    }
    return url
  }

  private static func makePixelBuffer(color: RGB, size: CGSize) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      Int(size.width),
      Int(size.height),
      kCVPixelFormatType_32BGRA,
      [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      ] as CFDictionary,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
      throw NSError(domain: "ThumbnailTimestampFixture", code: 3)
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue
      )
    else {
      throw NSError(domain: "ThumbnailTimestampFixture", code: 4)
    }

    // Logical RGB fill; CoreGraphics writes the correct BGRA bytes.
    context.setFillColor(
      red: CGFloat(color.r) / 255,
      green: CGFloat(color.g) / 255,
      blue: CGFloat(color.b) / 255,
      alpha: 1
    )
    context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))

    return buffer
  }

  /// Decodes encoded image `data` and returns its average color (the frames are
  /// solid, so the average is the frame's color).
  static func decodedColor(_ data: Data) -> RGB? {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }

    var pixel = [UInt8](repeating: 0, count: 4)
    guard
      let context = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (pixel[0], pixel[1], pixel[2])
  }

  /// Returns the index of the palette color closest to `color`.
  static func nearestPaletteIndex(_ color: RGB, palette: [RGB]) -> Int {
    var bestIndex = 0
    var bestDistance = Int.max
    for (index, candidate) in palette.enumerated() {
      let dr = Int(color.r) - Int(candidate.r)
      let dg = Int(color.g) - Int(candidate.g)
      let db = Int(color.b) - Int(candidate.b)
      let distance = dr * dr + dg * dg + db * db
      if distance < bestDistance {
        bestDistance = distance
        bestIndex = index
      }
    }
    return bestIndex
  }
}
