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

  // MARK: - Custom slide start point

  func testCustomSlideStartPointTravelsThePixelDelta() {
    // The layer rests with its top-left at (400, 200) in Flutter coordinates
    // (Y down); the start point sits 300px left and 150px above it.
    let off = slideFromOffset(
      invP: 1, slideFrom: CGPoint(x: 100, y: 50), layerOrigin: CGPoint(x: 400, y: 200))

    XCTAssertEqual(off.x, -300, accuracy: 1e-6)
    // Core Graphics counts Y upwards, so a smaller Flutter Y moves up.
    XCTAssertEqual(off.y, 150, accuracy: 1e-6)
  }

  func testCustomSlideStartPointIsZeroAtRestAndLinearInInvP() {
    let from = CGPoint(x: 100, y: 50)
    let origin = CGPoint(x: 400, y: 200)

    let rest = slideFromOffset(invP: 0, slideFrom: from, layerOrigin: origin)
    XCTAssertEqual(rest.x, 0, accuracy: 1e-6)
    XCTAssertEqual(rest.y, 0, accuracy: 1e-6)

    let full = slideFromOffset(invP: 1, slideFrom: from, layerOrigin: origin)
    let half = slideFromOffset(invP: 0.5, slideFrom: from, layerOrigin: origin)
    XCTAssertEqual(half.x, full.x / 2, accuracy: 1e-6)
    XCTAssertEqual(half.y, full.y / 2, accuracy: 1e-6)
  }

  func testCustomSlideStartPointOnTheRestingCornerNeverMoves() {
    let origin = CGPoint(x: 400, y: 200)
    let off = slideFromOffset(invP: 1, slideFrom: origin, layerOrigin: origin)
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

// MARK: - Chroma key

/// Cross-platform parity guard for the chroma-key formula.
///
/// The golden table below is duplicated verbatim in the Kotlin test
/// (`android/src/test/.../ChromaKeyMathTest.kt`). Both run it against their own
/// implementation — Swift's `chromaKeyed(r:g:b:_:)`, which is baked into the
/// Core Image color cube, and Kotlin's `ChromaKeyMath`, which the GLSL shader
/// mirrors. If either platform drifts, one of these two tests fails immediately
/// instead of the difference surfacing later as "the key looks slightly
/// different on Android".
///
/// **When you change the formula, regenerate both tables.**
class ChromaKeyMathTests: XCTestCase {

  /// The config the golden table was computed for: SMPTE green, defaults.
  private let config = ChromaKeyConfig(
    keyR: Double(0x00) / 255.0,
    keyG: Double(0xB1) / 255.0,
    keyB: Double(0x40) / 255.0,
    similarity: 0.15,
    smoothness: 0.08,
    spill: 0.5,
    backgroundColor: -1,
    backgroundImage: nil
  )

  private let tolerance = 1e-4

  /// The same key with a different despill strength.
  private func withSpill(_ spill: Double) -> ChromaKeyConfig {
    ChromaKeyConfig(
      keyR: config.keyR, keyG: config.keyG, keyB: config.keyB,
      similarity: config.similarity, smoothness: config.smoothness,
      spill: spill, backgroundColor: -1, backgroundImage: nil)
  }

  private struct Golden {
    let name: String
    let r, g, b: Double
    let outR, outG, outB, alpha: Double
  }

  private let golden: [Golden] = [
    // The key color itself and its neighbourhood: removed completely.
    Golden(name: "key color", r: 0.0, g: 0.694118, b: 0.25098,
           outR: 0.218029, outG: 0.565088, outB: 0.343519, alpha: 0.0),
    Golden(name: "near key", r: 0.05, g: 0.72, b: 0.28,
           outR: 0.261122, outG: 0.595058, outB: 0.369608, alpha: 0.0),
    Golden(name: "bright screen", r: 0.35, g: 0.9, b: 0.5,
           outR: 0.525426, outG: 0.796183, outB: 0.574457, alpha: 0.0),
    // Half-lit screen: past the default similarity, so only mostly removed.
    // This is the documented brightness sensitivity, pinned on purpose.
    Golden(name: "dim screen 50%", r: 0.0, g: 0.347059, b: 0.12549,
           outR: 0.109015, outG: 0.282544, outB: 0.17176, alpha: 0.081671),
    // Neutrals sit at the chroma origin, far from any saturated key.
    Golden(name: "black", r: 0.0, g: 0.0, b: 0.0,
           outR: 0.0, outG: 0.0, outB: 0.0, alpha: 1.0),
    Golden(name: "mid gray", r: 0.5, g: 0.5, b: 0.5,
           outR: 0.5, outG: 0.5, outB: 0.5, alpha: 1.0),
    Golden(name: "white", r: 1.0, g: 1.0, b: 1.0,
           outR: 1.0, outG: 1.0, outB: 1.0, alpha: 1.0),
    // Skin tone — the calibration anchor quoted in the Dart docs.
    Golden(name: "skin tone", r: 0.86, g: 0.65, b: 0.53,
           outR: 0.86, outG: 0.65, outB: 0.53, alpha: 1.0),
    Golden(name: "pure red", r: 1.0, g: 0.0, b: 0.0,
           outR: 1.0, outG: 0.0, outB: 0.0, alpha: 1.0),
    Golden(name: "pure blue", r: 0.0, g: 0.0, b: 1.0,
           outR: 0.0, outG: 0.0, outB: 1.0, alpha: 1.0),
    // Kept, but despilled: the green cast is pulled out at full alpha.
    Golden(name: "green-spilled gray", r: 0.55, g: 0.75, b: 0.55,
           outR: 0.616767, outG: 0.710487, outB: 0.578338, alpha: 1.0),
    // Leans away from the key hue, so despill leaves it alone.
    Golden(name: "magenta", r: 0.8, g: 0.2, b: 0.8,
           outR: 0.8, outG: 0.2, outB: 0.8, alpha: 1.0),
  ]

  func testGoldenTableMatchesTheSharedFormula() {
    for row in golden {
      let out = chromaKeyed(r: row.r, g: row.g, b: row.b, config)
      XCTAssertEqual(out.r, row.outR, accuracy: tolerance, "\(row.name): r")
      XCTAssertEqual(out.g, row.outG, accuracy: tolerance, "\(row.name): g")
      XCTAssertEqual(out.b, row.outB, accuracy: tolerance, "\(row.name): b")
      XCTAssertEqual(out.a, row.alpha, accuracy: tolerance, "\(row.name): alpha")
    }
  }

  func testKeyColorIsRemovedCompletely() {
    let out = chromaKeyed(r: config.keyR, g: config.keyG, b: config.keyB, config)
    XCTAssertEqual(out.a, 0.0, accuracy: tolerance)
  }

  func testSoftEdgeProducesPartialAlpha() {
    // Walk the key color toward neutral gray and collect the alpha ramp.
    let ramp: [Double] = (0...60).map { step in
      let t = Double(step) / 60.0
      return chromaKeyed(
        r: config.keyR + (0.5 - config.keyR) * t,
        g: config.keyG + (0.5 - config.keyG) * t,
        b: config.keyB + (0.5 - config.keyB) * t,
        config
      ).a
    }

    XCTAssertTrue(ramp.contains(0.0), "expected a fully keyed sample")
    XCTAssertTrue(ramp.contains(1.0), "expected a fully opaque sample")
    XCTAssertTrue(
      ramp.contains { $0 > 0.01 && $0 < 0.99 },
      "expected a soft edge, but alpha jumped straight from 0 to 1")
  }

  func testSpillPullsTheKeyCastOutWithoutDarkening() {
    let noSpill = withSpill(0.0)
    let fullSpill = withSpill(1.0)

    let without = chromaKeyed(r: 0.55, g: 0.75, b: 0.55, noSpill)
    let with = chromaKeyed(r: 0.55, g: 0.75, b: 0.55, fullSpill)

    let castBefore = without.g - max(without.r, without.b)
    let castAfter = with.g - max(with.r, with.b)
    XCTAssertLessThan(castAfter, castBefore, "despill did not reduce the green cast")

    // Luma is preserved, so despill never darkens the subject.
    XCTAssertEqual(
      lumaOf(r: without.r, g: without.g, b: without.b),
      lumaOf(r: with.r, g: with.g, b: with.b),
      accuracy: 1e-3)
  }

  func testMatteIsBrightnessSensitiveAsDocumented() {
    // Cb/Cr scale with brightness, so a dimly lit patch of the screen sits
    // closer to neutral and further from the key point. The default similarity
    // covers roughly 55%..100% of the reference brightness. Pinned because the
    // Dart docs promise exactly this.
    func screenAt(_ fraction: Double) -> Double {
      chromaKeyed(
        r: config.keyR * fraction, g: config.keyG * fraction,
        b: config.keyB * fraction, config
      ).a
    }

    XCTAssertEqual(screenAt(1.0), 0.0, accuracy: tolerance)
    XCTAssertEqual(screenAt(0.55), 0.0, accuracy: tolerance)
    XCTAssertGreaterThan(screenAt(0.5), 0.0, "a half-lit screen should start to survive")
  }

  func testNeutralKeyColorDisablesDespillInsteadOfDividingByZero() {
    let gray = ChromaKeyConfig(
      keyR: 0.5, keyG: 0.5, keyB: 0.5, similarity: 0.15, smoothness: 0.08,
      spill: 1.0, backgroundColor: -1, backgroundImage: nil)

    XCTAssertEqual(gray.keyDirection.cb, 0.0, accuracy: tolerance)
    XCTAssertEqual(gray.keyDirection.cr, 0.0, accuracy: tolerance)

    let out = chromaKeyed(r: 0.8, g: 0.2, b: 0.4, gray)
    XCTAssertFalse(out.r.isNaN || out.g.isNaN || out.b.isNaN || out.a.isNaN)
  }

  /// The cube is what actually runs on Apple, so verify it carries the same
  /// numbers **and** that its entries are premultiplied, which `CIColorCube`
  /// requires and which is the one place Apple and Android must differ.
  func testCubeIsPremultipliedAndMatchesTheFormula() throws {
    let size = 33
    let data = try XCTUnwrap(
      generateChromaLUTData(chroma: config, size: size))

    XCTAssertEqual(data.count, size * size * size * 4 * MemoryLayout<Float>.size)

    let floats: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

    // Walk the cube's own sample grid, so no interpolation is involved.
    for bi in stride(from: 0, to: size, by: 8) {
      for gi in stride(from: 0, to: size, by: 8) {
        for ri in stride(from: 0, to: size, by: 8) {
          let rf = Double(ri) / Double(size - 1)
          let gf = Double(gi) / Double(size - 1)
          let bf = Double(bi) / Double(size - 1)
          let expected = chromaKeyed(r: rf, g: gf, b: bf, config)

          let offset = (bi * size * size + gi * size + ri) * 4
          XCTAssertEqual(
            Double(floats[offset]), expected.r * expected.a, accuracy: 1e-5)
          XCTAssertEqual(
            Double(floats[offset + 1]), expected.g * expected.a, accuracy: 1e-5)
          XCTAssertEqual(
            Double(floats[offset + 2]), expected.b * expected.a, accuracy: 1e-5)
          XCTAssertEqual(Double(floats[offset + 3]), expected.a, accuracy: 1e-5)
        }
      }
    }
  }

  /// A fully keyed entry must be `(0, 0, 0, 0)`, not `(rgb, 0)` — Core Image
  /// would otherwise composite the key color back in at the edges.
  func testFullyKeyedCubeEntriesAreZero() throws {
    let size = 33
    let data = try XCTUnwrap(
      generateChromaLUTData(chroma: config, size: size))
    let floats: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

    // Nearest grid point to the key color.
    let ri = Int((config.keyR * Double(size - 1)).rounded())
    let gi = Int((config.keyG * Double(size - 1)).rounded())
    let bi = Int((config.keyB * Double(size - 1)).rounded())
    let offset = (bi * size * size + gi * size + ri) * 4

    XCTAssertEqual(floats[offset + 3], 0.0, accuracy: 1e-5, "key should be fully removed")
    XCTAssertEqual(floats[offset], 0.0, accuracy: 1e-5, "premultiplied red must be 0")
    XCTAssertEqual(floats[offset + 1], 0.0, accuracy: 1e-5, "premultiplied green must be 0")
    XCTAssertEqual(floats[offset + 2], 0.0, accuracy: 1e-5, "premultiplied blue must be 0")
  }

  /// Two different background images of the same byte length must not share a
  /// cache entry, or the second clip renders the first one's backdrop.
  func testCacheKeySeparatesEqualLengthBackgrounds() {
    func withBackground(_ bytes: [UInt8]) -> ChromaKeyConfig {
      ChromaKeyConfig(
        keyR: config.keyR, keyG: config.keyG, keyB: config.keyB,
        similarity: config.similarity, smoothness: config.smoothness,
        spill: config.spill, backgroundColor: -1,
        backgroundImage: .bytes(Data(bytes)))
    }

    let a = withBackground(Array(repeating: 0x11, count: 128))
    var bBytes = Array(repeating: UInt8(0x11), count: 128)
    bBytes[0] = 0x22
    let b = withBackground(bBytes)

    XCTAssertEqual(a.backgroundImage?.data?.count, b.backgroundImage?.data?.count)
    XCTAssertNotEqual(a.cacheKey, b.cacheKey)
    XCTAssertEqual(a.cacheKey, withBackground(Array(repeating: 0x11, count: 128)).cacheKey)
  }

  /// A key with no background image at all keeps a stable, distinct key.
  func testCacheKeyIsStableWithoutABackgroundImage() {
    XCTAssertEqual(config.cacheKey, config.cacheKey)
    XCTAssertNotEqual(config.cacheKey, withSpill(0.9).cacheKey)
  }

}

// MARK: - EXIF orientation on caller-supplied images

/// `decodeOrientedImage` must honor the EXIF `Orientation` tag.
///
/// A phone stores a portrait photo as *landscape* pixels plus a tag saying how
/// to turn them, and the chroma-key background and image layers are fed exactly
/// those bytes. This is the decode that keeps them upright, and that keeps iOS,
/// macOS and Android agreeing on the same input — Android pins the same contract
/// in `ImageOrientationTest`.
///
/// The fixtures are built here rather than checked in because the usual encoders
/// bake the orientation into the pixels and drop the tag, so a "landscape pixels
/// + Orientation=6" image cannot be produced by round-tripping one. The APP1
/// EXIF segment is spliced in by hand instead; see
/// `OrientedImageFixture.tagging(_:orientation:)`.
class DecodeOrientedImageTests: XCTestCase {

  /// Stored (pre-orientation) size: deliberately landscape, so an orientation
  /// that is honored is visible as a portrait result.
  private let storedWidth = 32
  private let storedHeight = 16

  /// EXIF 6: "the 0th row is the visual right side" — display by rotating the
  /// stored pixels 90° clockwise.
  private let rotate90 = OrientedImageFixture.orientationRotate90

  private func untaggedJpeg() throws -> Data {
    try XCTUnwrap(OrientedImageFixture.quadrantJpeg(width: storedWidth, height: storedHeight))
  }

  private func taggedJpeg() throws -> Data {
    OrientedImageFixture.tagging(try untaggedJpeg(), orientation: rotate90)
  }

  /// Guards the hand-written APP1 segment itself. Without this, a splice that
  /// silently produced no tag would make every "not rotated" assertion below
  /// pass for the wrong reason.
  func testFixtureCarriesTheOrientationTagItClaimsTo() throws {
    XCTAssertEqual(OrientedImageFixture.declaredOrientation(try taggedJpeg()), rotate90)
    XCTAssertEqual(OrientedImageFixture.declaredOrientation(try untaggedJpeg()), nil)
  }

  func testExifOrientationSwapsTheDecodedDimensions() throws {
    let image = try XCTUnwrap(decodeOrientedImage(try taggedJpeg()))

    // Swapped relative to the pixels actually stored in the file.
    XCTAssertEqual(image.extent.width, CGFloat(storedHeight))
    XCTAssertEqual(image.extent.height, CGFloat(storedWidth))
    XCTAssertEqual(image.extent.origin, .zero)
  }

  /// The counter-test: without it, "rotate everything" would satisfy the
  /// assertion above.
  func testUntaggedImageIsNotRotated() throws {
    let image = try XCTUnwrap(decodeOrientedImage(try untaggedJpeg()))

    XCTAssertEqual(image.extent.width, CGFloat(storedWidth))
    XCTAssertEqual(image.extent.height, CGFloat(storedHeight))
    XCTAssertEqual(image.extent.origin, .zero)
  }

  /// Extent alone would also be satisfied by a decode that swapped the size and
  /// left the pixels where they were, so check where the quadrants landed.
  ///
  /// Rotating the stored image 90° clockwise sends top-left → top-right,
  /// top-right → bottom-right, bottom-right → bottom-left, bottom-left →
  /// top-left.
  func testExifOrientationRotatesThePixelsAndNotJustTheExtent() throws {
    let image = try XCTUnwrap(decodeOrientedImage(try taggedJpeg()))
    let quadrants = try XCTUnwrap(OrientedImageFixture.quadrants(of: image))

    XCTAssertEqual(quadrants.topLeft, .bottomLeft)
    XCTAssertEqual(quadrants.topRight, .topLeft)
    XCTAssertEqual(quadrants.bottomLeft, .bottomRight)
    XCTAssertEqual(quadrants.bottomRight, .topRight)
  }

  func testUntaggedImageKeepsItsQuadrantsWhereTheyWere() throws {
    let image = try XCTUnwrap(decodeOrientedImage(try untaggedJpeg()))
    let quadrants = try XCTUnwrap(OrientedImageFixture.quadrants(of: image))

    XCTAssertEqual(quadrants.topLeft, .topLeft)
    XCTAssertEqual(quadrants.topRight, .topRight)
    XCTAssertEqual(quadrants.bottomLeft, .bottomLeft)
    XCTAssertEqual(quadrants.bottomRight, .bottomRight)
  }

  /// The case `NSImage` used to paper over on macOS: it rasterized every source
  /// into RGB before the compositor saw it, whereas `CGImageSource` hands back
  /// the file's own color space — so a one-component grayscale JPEG now reaches
  /// CoreImage as gray, and the render path's `CIContext` does no color
  /// management (`workingColorSpace: NSNull`). Pins that such an image still
  /// lands on the right pixels, and still turns.
  ///
  /// Classified by rank, not by value: a transfer function may move the levels,
  /// but it must not reorder them, and `grayQuadrants` refuses to guess when two
  /// of them come back equal — which is what a flattened or blank decode looks
  /// like.
  func testGrayscaleImageDecodesAndStillOrients() throws {
    let untagged = try XCTUnwrap(
      OrientedImageFixture.grayscaleQuadrantJpeg(width: storedWidth, height: storedHeight))
    let tagged = OrientedImageFixture.tagging(untagged, orientation: rotate90)

    let plain = try XCTUnwrap(decodeOrientedImage(untagged))
    XCTAssertEqual(plain.extent.width, CGFloat(storedWidth))
    XCTAssertEqual(plain.extent.height, CGFloat(storedHeight))
    let asStored = try XCTUnwrap(OrientedImageFixture.grayQuadrants(of: plain))
    XCTAssertEqual(asStored.topLeft, .topLeft)
    XCTAssertEqual(asStored.topRight, .topRight)
    XCTAssertEqual(asStored.bottomLeft, .bottomLeft)
    XCTAssertEqual(asStored.bottomRight, .bottomRight)

    let rotated = try XCTUnwrap(decodeOrientedImage(tagged))
    XCTAssertEqual(rotated.extent.width, CGFloat(storedHeight))
    XCTAssertEqual(rotated.extent.height, CGFloat(storedWidth))
    let asDisplayed = try XCTUnwrap(OrientedImageFixture.grayQuadrants(of: rotated))
    XCTAssertEqual(asDisplayed.topLeft, .bottomLeft)
    XCTAssertEqual(asDisplayed.topRight, .topLeft)
    XCTAssertEqual(asDisplayed.bottomLeft, .bottomRight)
    XCTAssertEqual(asDisplayed.bottomRight, .topRight)
  }

  func testUndecodableBytesReturnNil() {
    XCTAssertNil(decodeOrientedImage(Data([0x00, 0x01, 0x02, 0x03])))
    XCTAssertNil(decodeOrientedImage(Data()))
  }
}

// MARK: - EXIF orientation test fixtures

/// Builds and reads back the EXIF-orientation fixtures.
///
/// Duplicated in the iOS and macOS RunnerTests: they are separate test targets
/// with no shared source directory, as `ThumbnailTimestampFixture` already is.
/// Keep the two copies in step.
enum OrientedImageFixture {

  /// EXIF `Orientation` = 6, i.e. display by rotating the stored pixels 90° CW.
  static let orientationRotate90: UInt32 = 6

  /// Which corner of the *stored* image a color came from. Each quadrant of the
  /// fixture gets its own color, so a rotation is readable as a permutation.
  enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var rgb: (r: UInt8, g: UInt8, b: UInt8) {
      switch self {
      case .topLeft: return (255, 0, 0)  // red
      case .topRight: return (0, 255, 0)  // green
      case .bottomLeft: return (0, 0, 255)  // blue
      case .bottomRight: return (255, 255, 0)  // yellow
      }
    }

    /// The grayscale fixture's level for this corner. Strictly increasing in
    /// the order the cases are declared, which is what lets `grayQuadrants`
    /// classify by rank instead of by value.
    var gray: UInt8 {
      switch self {
      case .topLeft: return 16
      case .topRight: return 96
      case .bottomLeft: return 176
      case .bottomRight: return 248
      }
    }
  }

  struct Quadrants {
    let topLeft: Corner
    let topRight: Corner
    let bottomLeft: Corner
    let bottomRight: Corner
  }

  /// A JPEG whose four quadrants are four distinct flat colors.
  ///
  /// Built from raw top-down raster bytes, so "row 0 is the top" is a property of
  /// the fixture rather than something the test has to assume about a drawing
  /// context.
  static func quadrantJpeg(width: Int, height: Int) -> Data? {
    var raster = [UInt8]()
    raster.reserveCapacity(width * height * 4)
    for row in 0..<height {
      for col in 0..<width {
        let rgb = corner(col: col, row: row, width: width, height: height).rgb
        raster.append(contentsOf: [rgb.r, rgb.g, rgb.b, 255])
      }
    }

    guard let provider = CGDataProvider(data: Data(raster) as CFData),
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent)
    else { return nil }

    return encodeJpeg(image)
  }

  /// A one-component grayscale JPEG whose four quadrants are four distinct gray
  /// levels — the same layout as `quadrantJpeg`, in a color space that is not
  /// RGB.
  static func grayscaleQuadrantJpeg(width: Int, height: Int) -> Data? {
    var raster = [UInt8]()
    raster.reserveCapacity(width * height)
    for row in 0..<height {
      for col in 0..<width {
        raster.append(corner(col: col, row: row, width: width, height: height).gray)
      }
    }

    guard let provider = CGDataProvider(data: Data(raster) as CFData),
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent)
    else { return nil }

    return encodeJpeg(image)
  }

  /// Encodes `image` as a maximum-quality JPEG: the quadrant centers are sampled
  /// far from the color edges, so what ringing survives cannot flip a
  /// classification.
  private static func encodeJpeg(_ image: CGImage) -> Data? {
    let encoded = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        encoded, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image,
      [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return encoded as Data
  }

  /// Splices a minimal APP1 EXIF segment declaring `orientation` into `jpeg`.
  ///
  /// Written out byte by byte because the encoders bake the orientation in and
  /// drop the tag: a TIFF header, one IFD entry for tag `0x0112` (Orientation),
  /// type SHORT, and no next IFD.
  static func tagging(_ jpeg: Data, orientation: UInt32) -> Data {
    let app1: [UInt8] = [
      0xFF, 0xE1, 0x00, 0x22,  // APP1, length 34 = 2 + 32 bytes of payload
      0x45, 0x78, 0x69, 0x66, 0x00, 0x00,  // "Exif\0\0"
      0x4D, 0x4D, 0x00, 0x2A,  // TIFF header, big-endian ("MM")
      0x00, 0x00, 0x00, 0x08,  // IFD0 sits 8 bytes in
      0x00, 0x01,  // one entry
      0x01, 0x12,  // tag 0x0112: Orientation
      0x00, 0x03,  // type 3: SHORT
      0x00, 0x00, 0x00, 0x01,  // count 1
      0x00, UInt8(orientation), 0x00, 0x00,  // the value, left-aligned
      0x00, 0x00, 0x00, 0x00,  // no next IFD
    ]

    var bytes = [UInt8](jpeg)
    bytes.insert(contentsOf: app1, at: app1InsertionPoint(bytes))
    return Data(bytes)
  }

  /// The EXIF orientation `jpeg` declares, or nil when it declares none.
  static func declaredOrientation(_ jpeg: Data) -> UInt32? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return nil }
    return properties[kCGImagePropertyOrientation] as? UInt32
  }

  /// Classifies the four quadrant centers of `image` back to the stored corner
  /// each color came from.
  static func quadrants(of image: CIImage) -> Quadrants? {
    guard let raster = raster(of: image) else { return nil }
    let (pixels, width, height) = raster
    guard width >= 2, height >= 2 else { return nil }

    func corner(atFractionX fx: Double, y fy: Double) -> Corner {
      let col = min(width - 1, Int(Double(width) * fx))
      let row = min(height - 1, Int(Double(height) * fy))
      let offset = (row * width + col) * 4
      return nearestCorner((pixels[offset], pixels[offset + 1], pixels[offset + 2]))
    }

    return Quadrants(
      topLeft: corner(atFractionX: 0.25, y: 0.25),
      topRight: corner(atFractionX: 0.75, y: 0.25),
      bottomLeft: corner(atFractionX: 0.25, y: 0.75),
      bottomRight: corner(atFractionX: 0.75, y: 0.75))
  }

  /// Classifies the four quadrant centers of a grayscale `image` back to the
  /// stored corner each level came from, by **rank** rather than by value: the
  /// decode may put the levels through a transfer function, but it must not
  /// reorder them.
  ///
  /// Returns nil when two centers come back equal — a flattened or blank decode
  /// would otherwise be ranked into some arbitrary permutation and could pass by
  /// luck.
  static func grayQuadrants(of image: CIImage) -> Quadrants? {
    guard let raster = raster(of: image) else { return nil }
    let (pixels, width, height) = raster
    guard width >= 2, height >= 2 else { return nil }

    func level(atFractionX fx: Double, y fy: Double) -> UInt8 {
      let col = min(width - 1, Int(Double(width) * fx))
      let row = min(height - 1, Int(Double(height) * fy))
      return pixels[(row * width + col) * 4]
    }

    // Positions in the order Quadrants declares them.
    let levels = [
      level(atFractionX: 0.25, y: 0.25),
      level(atFractionX: 0.75, y: 0.25),
      level(atFractionX: 0.25, y: 0.75),
      level(atFractionX: 0.75, y: 0.75),
    ]
    guard Set(levels).count == levels.count else { return nil }

    // Corner.allCases is declared darkest-first, matching Corner.gray.
    let darkestFirst = Corner.allCases
    var corners = [Corner](repeating: .topLeft, count: levels.count)
    for (rank, position) in levels.enumerated()
      .sorted(by: { $0.element < $1.element })
      .map({ $0.offset })
      .enumerated()
    {
      corners[position] = darkestFirst[rank]
    }

    return Quadrants(
      topLeft: corners[0], topRight: corners[1],
      bottomLeft: corners[2], bottomRight: corners[3])
  }

  /// Which corner of the stored image the pixel at (`col`, `row`) belongs to,
  /// with row 0 the top.
  private static func corner(col: Int, row: Int, width: Int, height: Int) -> Corner {
    let isLeft = col < width / 2
    let isTop = row < height / 2
    if isTop { return isLeft ? .topLeft : .topRight }
    return isLeft ? .bottomLeft : .bottomRight
  }

  /// `image`'s pixels in raster order, row 0 the top.
  private static func raster(of image: CIImage) -> (
    pixels: [UInt8], width: Int, height: Int
  )? {
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }

    let width = cgImage.width
    let height = cgImage.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let bitmap = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (pixels, width, height)
  }

  /// The quadrant color closest to `color`, so JPEG ringing does not matter.
  private static func nearestCorner(_ color: (r: UInt8, g: UInt8, b: UInt8)) -> Corner {
    var best = Corner.topLeft
    var bestDistance = Int.max
    for candidate in Corner.allCases {
      let rgb = candidate.rgb
      let dr = Int(color.r) - Int(rgb.r)
      let dg = Int(color.g) - Int(rgb.g)
      let db = Int(color.b) - Int(rgb.b)
      let distance = dr * dr + dg * dg + db * db
      if distance < bestDistance {
        bestDistance = distance
        best = candidate
      }
    }
    return best
  }

  /// Where an APP1 segment may be inserted: after SOI, and after a leading JFIF
  /// APP0 if the encoder wrote one — putting it first would leave a JFIF file
  /// whose APP0 no longer follows SOI. Being the *first* APP1 is what matters,
  /// since that is the one a reader takes.
  private static func app1InsertionPoint(_ bytes: [UInt8]) -> Int {
    var index = 2  // past SOI (FFD8)
    while index + 4 <= bytes.count, bytes[index] == 0xFF, bytes[index + 1] == 0xE0 {
      index += 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
    }
    return index
  }
}
