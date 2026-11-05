import AVFoundation
import CoreImage
import ImageIO
import XCTest

@testable import pro_video_editor

// Compiled into *both* the iOS and the macOS RunnerTests target (referenced
// from each project as ../shared_tests/…): the compositor is shared Darwin
// code, mirrored by HalfOpenTimeRangeTest.kt on Android.

/// Image layers and color filters show from their start up to, but not
/// including, their end, as clips and video effects do. A frame at exactly the
/// end shows what comes after it, so of two layers that meet there, such as
/// the parts of a text whose words light up one by one, only the later one is
/// drawn.
final class LayerTimeRangeTests: XCTestCase {
  private let frame = CGRect(x: 0, y: 0, width: 80, height: 40)

  func testARangeShowsUpToButNotIncludingItsEnd() {
    XCTAssertFalse(isWithinTimeRange(999, startUs: 1_000, endUs: 2_000))
    XCTAssertTrue(isWithinTimeRange(1_000, startUs: 1_000, endUs: 2_000))
    XCTAssertTrue(isWithinTimeRange(1_999, startUs: 1_000, endUs: 2_000))
    XCTAssertFalse(isWithinTimeRange(2_000, startUs: 1_000, endUs: 2_000))
  }

  func testMinusOneLeavesThatSideOpen() {
    XCTAssertTrue(isWithinTimeRange(0, startUs: -1, endUs: 2_000))
    XCTAssertFalse(isWithinTimeRange(2_000, startUs: -1, endUs: 2_000))
    XCTAssertTrue(isWithinTimeRange(.max, startUs: 1_000, endUs: -1))
    XCTAssertTrue(isWithinTimeRange(0, startUs: -1, endUs: -1))
  }

  func testOfTwoLayersThatMeetOnlyTheLaterOneIsDrawnWhereTheyMeet() {
    // Red over the left half until 500 ms, green over the right half from
    // there until 1 s, on a blue frame.
    let compositor = VideoCompositor()
    compositor.setOverlayImageLayers(from: [
      layer(CGColor(red: 1, green: 0, blue: 0, alpha: 1), x: 0, startUs: 0, endUs: 500_000),
      layer(
        CGColor(red: 0, green: 1, blue: 0, alpha: 1), x: 40, startUs: 500_000, endUs: 1_000_000),
    ])

    XCTAssertEqual(colors(compositor, atUs: 499_999), [.red, .blue])
    XCTAssertEqual(colors(compositor, atUs: 500_000), [.blue, .green])
    XCTAssertEqual(colors(compositor, atUs: 999_999), [.blue, .green])
    XCTAssertEqual(colors(compositor, atUs: 1_000_000), [.blue, .blue])
  }

  func testALayerWithoutAnEndShowsUntilTheEndOfTheVideo() {
    let compositor = VideoCompositor()
    compositor.setOverlayImageLayers(from: [
      layer(CGColor(red: 1, green: 0, blue: 0, alpha: 1), x: 0, startUs: -1, endUs: -1)
    ])

    XCTAssertEqual(colors(compositor, atUs: 0), [.red, .blue])
    XCTAssertEqual(colors(compositor, atUs: 3_600_000_000), [.red, .blue])
  }

  func testAColorFilterAppliesUpToButNotIncludingItsEnd() {
    let compositor = VideoCompositor()
    var config = VideoCompositorConfig()
    config.colorFilterConfigs = [
      ColorFilterConfig(
        matrix: [0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
        startUs: 250_000, endUs: 500_000)
    ]
    compositor.apply(config)

    XCTAssertNil(compositor.getLUTForActiveFilters(at: time(249_000)))
    XCTAssertNotNil(compositor.getLUTForActiveFilters(at: time(250_000)))
    XCTAssertNotNil(compositor.getLUTForActiveFilters(at: time(499_999)))
    XCTAssertNil(compositor.getLUTForActiveFilters(at: time(500_000)))
  }

  func testAFrameOnTheEndIsReadAsTheEndItself() {
    // 30 fps at timescale 600: the frame at 4.1 s is 4.0999999… s as a
    // Double, which used to truncate to 4 099 999 µs and still draw a layer or
    // filter ending at 4.1 s on it.
    let frameAtEnd = CMTime(value: 2_460, timescale: 600)

    XCTAssertEqual(compositionTimeUs(frameAtEnd), 4_100_000)
    XCTAssertFalse(
      isWithinTimeRange(compositionTimeUs(frameAtEnd), startUs: 0, endUs: 4_100_000))

    let compositor = VideoCompositor()
    var config = VideoCompositorConfig()
    config.colorFilterConfigs = [
      ColorFilterConfig(
        matrix: [0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
        startUs: 0, endUs: 4_100_000)
    ]
    compositor.apply(config)

    XCTAssertNotNil(
      compositor.getLUTForActiveFilters(at: CMTime(value: 2_440, timescale: 600)))
    XCTAssertNil(compositor.getLUTForActiveFilters(at: frameAtEnd))
  }

  // MARK: - Helpers

  private enum Color { case red, green, blue, other }

  private func time(_ us: Int64) -> CMTime {
    CMTime(value: us, timescale: 1_000_000)
  }

  /// A layer filling the left or right half of the frame with `color`.
  private func layer(_ color: CGColor, x: Int64, startUs: Int64, endUs: Int64)
    -> ImageLayerConfig
  {
    ImageLayerConfig(
      image: .bytes(png(color)), startUs: startUs, endUs: endUs, x: x, y: 0, width: 40,
      height: 40, rotation: 0, loop: true, animationOffsetUs: 0, animations: [])
  }

  /// The color in the middle of the left and of the right half of the blue
  /// frame `compositor` draws its overlay layers over at `timeUs`.
  private func colors(_ compositor: VideoCompositor, atUs timeUs: Int64) -> [Color] {
    let backdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: frame)
    let drawn = compositor.drawOverlayLayers(over: backdrop, imageRect: frame, atUs: timeUs)
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    return [20, 60].map { x in
      var pixel = [UInt8](repeating: 0, count: 4)
      context.render(
        drawn, toBitmap: &pixel, rowBytes: 4,
        bounds: CGRect(x: CGFloat(x), y: 20, width: 1, height: 1), format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
      switch (pixel[0] > 200, pixel[1] > 200, pixel[2] > 200) {
      case (true, false, false): return .red
      case (false, true, false): return .green
      case (false, false, true): return .blue
      default: return .other
      }
    }
  }

  private func png(_ color: CGColor) -> Data {
    let context = CGContext(
      data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
  }
}
