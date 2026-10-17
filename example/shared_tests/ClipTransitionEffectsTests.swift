import CoreImage
import CoreMedia
import XCTest

@testable import pro_video_editor

// Compiled into *both* the iOS and the macOS RunnerTests target (referenced
// from each project as ../shared_tests/…): the transitions are shared Darwin
// code, mirrored by ClipTransitionEffectsTest.kt on Android.

/// The transitions `ClipTransitionCompositor` draws with Core Image.
final class ClipTransitionEffectsTests: XCTestCase {
  private typealias Effects = ClipTransitionEffects

  private let size = CGSize(width: 48, height: 64)
  private let types = [
    "zoomIn", "zoomOut", "spin", "whipPan", "blur", "glitch", "flash", "iris", "stretch",
  ]
  private let context = CIContext(options: [
    .workingColorSpace: NSNull(),
    .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
  ])

  /// An opaque frame whose RGB at each top-origin pixel is `color(x, y)`.
  private func frame(_ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CIImage {
    let width = Int(size.width)
    let height = Int(size.height)
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let (r, g, b) = color(x, y)
        let i = (y * width + x) * 4
        bytes[i] = r
        bytes[i + 1] = g
        bytes[i + 2] = b
      }
    }
    return CIImage(
      bitmapData: Data(bytes), bytesPerRow: width * 4, size: size, format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
  }

  private func flat(_ value: UInt8) -> CIImage { frame { _, _ in (value, value, value) } }

  /// The rendered frame's RGBA bytes, rows from the top.
  private func pixels(_ image: CIImage) -> [UInt8] {
    let width = Int(size.width)
    let height = Int(size.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    context.render(
      image, toBitmap: &bytes, rowBytes: width * 4,
      bounds: CGRect(origin: .zero, size: size), format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return bytes
  }

  /// Red, green and blue of the top-origin pixel (`x`, `y`).
  private func rgb(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [Int] {
    let i = (y * Int(size.width) + x) * 4
    return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
  }

  private func compose(
    _ type: String, _ a: CIImage, _ b: CIImage, _ p: Double, direction: String = "left"
  ) -> [UInt8] {
    pixels(
      Effects.compose(
        type: type, direction: direction, outgoing: a, incoming: b, size: size,
        progress: p, linearProgress: p, durationUs: 500_000))
  }

  private func assertClose(
    _ actual: [UInt8], _ expected: [UInt8], tolerance: Int = 1, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let worst = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
    XCTAssertLessThanOrEqual(worst, tolerance, message, file: file, line: line)
  }

  // A picture with detail everywhere, so a misplaced pixel shows.
  private lazy var outgoing = frame { x, y in
    (UInt8((x * 7 + y * 3) % 256), UInt8((x * 3) % 256), UInt8((y * 5) % 256))
  }
  private lazy var incoming = frame { x, y in
    (UInt8((x * 11) % 256), UInt8((x + y * 13) % 256), UInt8((x * 2 + y) % 256))
  }

  func testEveryTypeStartsOnTheOutgoingFrameAndEndsOnTheIncomingOne() {
    let a = pixels(outgoing)
    let b = pixels(incoming)
    for type in types {
      for direction in ["left", "right", "up", "down"] {
        assertClose(
          compose(type, outgoing, incoming, 0, direction: direction), a, "\(type) \(direction) at 0")
        assertClose(
          compose(type, outgoing, incoming, 1, direction: direction), b, "\(type) \(direction) at 1")
      }
    }
  }

  func testHandlesOnlyTheNewTypes() {
    for type in types { XCTAssertTrue(Effects.handles(type), type) }
    for type in ["dissolve", "slide", "push", "wipe", "fadeToBlack", "fadeToWhite"] {
      XCTAssertFalse(Effects.handles(type), type)
    }
  }

  func testTheNewTypesOverlapTheClips() {
    for type in types {
      let config = ClipTransitionConfig(
        type: type, durationUs: 500_000, curve: "linear", direction: "left")
      XCTAssertTrue(config.isOverlap, type)
      XCTAssertFalse(config.isDip, type)
    }
  }

  func testIrisShowsTheIncomingClipInTheMiddleAndTheOutgoingOneInTheCorners() {
    let out = compose("iris", flat(0), flat(255), 0.5)

    XCTAssertEqual(rgb(out, 24, 32), [255, 255, 255])
    XCTAssertEqual(rgb(out, 0, 0), [0, 0, 0])
    XCTAssertEqual(rgb(out, 47, 63), [0, 0, 0])
  }

  func testZoomInGrowsTheIncomingClipOutOfTheCenter() {
    let out = compose("zoomIn", flat(0), flat(255), 0.5)

    XCTAssertEqual(rgb(out, 24, 32), [255, 255, 255])
    XCTAssertEqual(rgb(out, 13, 17), [255, 255, 255])
    XCTAssertEqual(rgb(out, 10, 32), [0, 0, 0])
    XCTAssertEqual(rgb(out, 0, 0), [0, 0, 0])
  }

  func testZoomOutShrinksTheOutgoingClipOverTheIncomingOne() {
    let out = compose("zoomOut", flat(0), flat(255), 0.5)

    XCTAssertEqual(rgb(out, 24, 32), [0, 0, 0])
    XCTAssertEqual(rgb(out, 0, 0), [255, 255, 255])
  }

  func testSpinKeepsTheFrameCoveredAtEveryAngle() {
    for step in 0...20 {
      let p = Double(step) / 20
      let out = compose("spin", flat(40), flat(200), p)
      let first = rgb(out, 0, 0)
      for y in 0..<Int(size.height) {
        for x in 0..<Int(size.width) where abs(rgb(out, x, y)[0] - first[0]) > 1 {
          XCTFail("p=\(p) at \(x),\(y): \(rgb(out, x, y)) vs \(first)")
          return
        }
      }
    }
  }

  func testCoverScaleZoomsAQuarterTurnedPortraitFrameByItsAspectRatio() {
    let portrait = CGSize(width: 1080, height: 1920)
    XCTAssertEqual(Effects.coverScale(portrait, angle: 0), 1, accuracy: 1e-9)
    XCTAssertEqual(Effects.coverScale(portrait, angle: .pi / 2), 1920.0 / 1080, accuracy: 1e-9)
    XCTAssertEqual(Effects.coverScale(portrait, angle: .pi), 1, accuracy: 1e-9)
  }

  func testWhipPanBlursOnlyAlongItsMotion() {
    // Rows alternate dark and light, so a horizontal blur leaves them as they
    // are and a vertical one evens them out.
    let stripes = frame { _, y in y % 2 == 0 ? (40, 40, 40) : (200, 200, 200) }

    let sideways = compose("whipPan", stripes, stripes, 0.5, direction: "left")
    let upward = compose("whipPan", stripes, stripes, 0.5, direction: "up")

    XCTAssertEqual(rgb(sideways, 24, 32)[0], 40, accuracy: 1)
    XCTAssertEqual(rgb(sideways, 24, 33)[0], 200, accuracy: 1)
    XCTAssertEqual(rgb(upward, 24, 32)[0], 120, accuracy: 10)
    XCTAssertEqual(rgb(upward, 24, 33)[0], 120, accuracy: 10)
  }

  func testBlurEvensOutDetailAtMidTransition() {
    let checks = frame { x, y in (x + y) % 2 == 0 ? (40, 40, 40) : (200, 200, 200) }

    let out = compose("blur", checks, checks, 0.5)

    for y in 8..<Int(size.height) - 8 {
      for x in 8..<Int(size.width) - 8 {
        XCTAssertEqual(rgb(out, x, y)[0], 120, accuracy: 3, "\(x),\(y)")
      }
    }
  }

  func testFlashIsWhiteAtItsPeak() {
    let out = compose("flash", outgoing, incoming, 0.5)

    XCTAssertEqual(Set(out), [255])
  }

  func testFlashStrengthPeaksOnlyAtTheMidpoint() {
    XCTAssertEqual(Effects.flashStrength(0), 0)
    XCTAssertEqual(Effects.flashStrength(0.5), 1)
    XCTAssertEqual(Effects.flashStrength(1), 0)
    XCTAssertLessThan(Effects.flashStrength(0.25), 1.0 / 6)
  }

  func testStretchSqueezesBothClipsIntoTheirShareOfTheFrame() {
    let ramp = frame { x, _ in (UInt8(20 + x * 4), 0, 0) }

    // Moving left at 0.25: the incoming clip takes the right quarter and the
    // outgoing ramp is squeezed into the left three quarters.
    let out = compose("stretch", ramp, flat(255), 0.25)

    XCTAssertEqual(rgb(out, 47, 32), [255, 255, 255])
    XCTAssertEqual(rgb(out, 36, 32), [255, 255, 255])
    // Column 18 reads the ramp at 18.5 / 0.75 - 0.5 = 24.17.
    XCTAssertEqual(rgb(out, 18, 32)[0], 20 + 4 * 24 + 1, accuracy: 1)
  }

  func testStretchEntersFromTheEdgeOppositeItsDirection() {
    let right = compose("stretch", flat(0), flat(255), 0.25, direction: "right")
    let down = compose("stretch", flat(0), flat(255), 0.25, direction: "down")
    let up = compose("stretch", flat(0), flat(255), 0.25, direction: "up")

    XCTAssertEqual(rgb(right, 0, 32)[0], 255)
    XCTAssertEqual(rgb(right, 47, 32)[0], 0)
    XCTAssertEqual(rgb(down, 24, 0)[0], 255)
    XCTAssertEqual(rgb(down, 24, 63)[0], 0)
    XCTAssertEqual(rgb(up, 24, 63)[0], 255)
    XCTAssertEqual(rgb(up, 24, 0)[0], 0)
  }

  func testGlitchCutsToTheIncomingClipHalfwayThrough() {
    let phase = Effects.glitchPhase(linearProgress: 0.7, durationUs: 500_000)
    let early = Effects.glitchBands(c: 0.3, phase: phase, width: 48)
    let late = Effects.glitchBands(c: 0.7, phase: phase, width: 48)
    XCTAssertTrue(early.filter { $0.shift == 0 }.allSatisfy { !$0.showsIncoming })
    XCTAssertTrue(late.filter { $0.shift == 0 }.allSatisfy { $0.showsIncoming })

    let out = compose("glitch", flat(0), flat(255), 0.7)
    for (index, band) in late.enumerated() where band.shift == 0 {
      XCTAssertGreaterThan(rgb(out, 24, index * 4)[1], 200, "band \(index)")
    }
  }

  func testGlitchHashMatchesTheAndroidPin() {
    // ClipTransitionEffectsTest.kt pins the same values, so both platforms
    // draw the same glitch.
    XCTAssertEqual(Effects.glitchHash(band: 0, phase: 0, salt: 0), 0.5737507424782962, accuracy: 1e-15)
    XCTAssertEqual(Effects.glitchHash(band: 3, phase: 7, salt: 1), 0.36553404899314046, accuracy: 1e-15)
    XCTAssertEqual(Effects.glitchHash(band: 15, phase: 40, salt: 2), 0.9913903491105884, accuracy: 1e-15)
  }

  func testGlitchPatternChangesFifteenTimesASecond() {
    XCTAssertEqual(Effects.glitchPhase(linearProgress: 0, durationUs: 1_000_000), 0)
    XCTAssertEqual(Effects.glitchPhase(linearProgress: 0.5, durationUs: 1_000_000), 7)
    XCTAssertEqual(Effects.glitchPhase(linearProgress: 1, durationUs: 1_000_000), 15)
    XCTAssertEqual(Effects.glitchPhase(linearProgress: 1, durationUs: 250_000), 3)
  }

  func testInstructionReachesFullProgressOnTheLastFrame() {
    let instruction = ClipTransitionInstruction(
      timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 2)),
      outgoingTrackID: 1, incomingTrackID: 2,
      outgoingTransform: .identity, incomingTransform: .identity,
      type: "zoomIn", direction: "left", curve: "linear",
      frameDuration: CMTime(value: 1, timescale: 30))

    XCTAssertEqual(instruction.linearProgress(at: .zero), 0)
    XCTAssertEqual(instruction.linearProgress(at: CMTime(value: 14, timescale: 30)), 1, accuracy: 1e-9)
    XCTAssertEqual(instruction.linearProgress(at: CMTime(value: 7, timescale: 30)), 0.5, accuracy: 1e-9)
  }
}
