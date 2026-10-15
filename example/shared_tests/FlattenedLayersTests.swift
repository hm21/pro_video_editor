import CoreImage
import Foundation
import ImageIO
import XCTest

@testable import pro_video_editor

// Compiled into *both* the iOS and the macOS RunnerTests target (referenced
// from each project as ../shared_tests/…), like AudioFadeTests.swift: the
// compositor is shared Darwin code.

/// Static layers in a row are drawn into one image (`FlattenedLayers`), so a
/// render with 200 stickers keeps one decoded image instead of 200. That image
/// has to look exactly like the layers drawn one by one.
final class FlattenedLayersTests: XCTestCase {
  private let frame = CGRect(x: 0, y: 0, width: 320, height: 180)

  // MARK: - Which layers are drawn together

  func testStaticLayersInARowFormOneRun() {
    let layers = Array(repeating: layer(), count: 5)

    XCTAssertEqual(staticLayerRunLength(layers, from: 0), 5)
    XCTAssertEqual(staticLayerRunLength(layers, from: 4), 1)
  }

  func testARunEndsWhereTheTimeRangeChanges() {
    let layers = [
      layer(startUs: 0, endUs: 1_000_000),
      layer(startUs: 0, endUs: 1_000_000),
      layer(startUs: 0, endUs: 2_000_000),
    ]

    XCTAssertEqual(staticLayerRunLength(layers, from: 0), 2)
  }

  func testARunEndsAtALayerThatChangesOverTime() {
    let fade = LayerAnimationConfig(
      type: "fade", phase: "animateIn", durationUs: 500_000, curve: "linear",
      slideDirection: nil, slideFrom: nil, scaleFrom: nil)
    let moving = [
      layer(animations: [fade]),
      layer(keyframes: [KeyframeConfig(timeUs: 0, x: 0, y: 0)]),
      layer(censor: LayerCensorConfig(type: .blur, strength: 10)),
      layer(image: .bytes(animatedGif())),
    ]

    for other in moving {
      XCTAssertEqual(staticLayerRunLength([layer(), other, layer()], from: 0), 1)
      XCTAssertEqual(staticLayerRunLength([other, layer()], from: 0), 0)
    }
  }

  func testOneOverlayDrawsAStaticRun() {
    let compositor = VideoCompositor()
    let fade = LayerAnimationConfig(
      type: "fade", phase: "animateIn", durationUs: 500_000, curve: "linear",
      slideDirection: nil, slideFrom: nil, scaleFrom: nil)

    compositor.setOverlayImageLayers(from: [layer(), layer(), layer(animations: [fade])])

    XCTAssertEqual(compositor.overlayImageLayers.count, 2)
    XCTAssertNotNil(compositor.overlayImageLayers[0].flattened)
    XCTAssertNil(compositor.overlayImageLayers[1].flattened)
  }

  // MARK: - What the image looks like

  func testTheImageLooksLikeTheLayersDrawnOneByOne() throws {
    let layers = [
      // Turned, and half red, half blue, so a mirrored or misplaced copy shows.
      layer(
        image: .bytes(twoColorPng()), x: 40, y: 20, width: 120, height: 60,
        rotation: 0.6),
      // Stretched over the frame, half transparent.
      layer(
        image: .bytes(png(CGColor(red: 0, green: 1, blue: 0, alpha: 0.5))),
        x: nil, y: nil, width: nil, height: nil),
      // Partly past the bottom-right corner.
      layer(
        image: .bytes(png(CGColor(red: 1, green: 1, blue: 0, alpha: 0.8))),
        x: 250, y: 140, width: 140, height: 80),
    ]
    let flattened = VideoCompositor()
    flattened.setOverlayImageLayers(from: layers)
    // Over time ranges of their own, the same layers are drawn one by one.
    let separate = VideoCompositor()
    separate.setOverlayImageLayers(
      from: layers.enumerated().map { index, layer in
        self.layer(layer, startUs: Int64(index))
      })
    XCTAssertEqual(flattened.overlayImageLayers.count, 1)
    XCTAssertEqual(separate.overlayImageLayers.count, 3)

    let background = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: frame)
    let expected = separate.overlayImageLayers.reduce(background) { image, layer in
      separate.drawImageLayer(layer, over: image, imageRect: frame, currentTimeUs: 1_000_000)
    }
    let actual = flattened.drawImageLayer(
      flattened.overlayImageLayers[0], over: background, imageRect: frame,
      currentTimeUs: 1_000_000)

    let expectedPixels = pixels(expected)
    let actualPixels = pixels(actual)
    XCTAssertEqual(actualPixels.count, expectedPixels.count)
    let largest = zip(actualPixels, expectedPixels).map { abs(Int($0) - Int($1)) }.max() ?? 0
    // One rounding step for the image the layers are drawn into.
    XCTAssertLessThanOrEqual(largest, 2)
    // The layers did draw: the stretched green one tints every pixel.
    XCTAssertNotEqual(pixels(background), actualPixels)
  }

  func testLayersThatDoNotDecodeDrawNothing() {
    let compositor = VideoCompositor()
    let broken = layer(image: .bytes(Data([0x89, 0x50, 0x4E, 0x47])))
    let run = FlattenedLayers(layers: [broken, broken])

    XCTAssertNil(compositor.flattenedImage(run, in: frame))
  }

  // MARK: - When the image is drawn

  func testTheImageIsDrawnOncePerFrameExtent() {
    let run = FlattenedLayers(layers: [])
    var draws = 0
    let draw: () -> CIImage? = {
      draws += 1
      return CIImage(color: .red).cropped(to: self.frame)
    }

    _ = run.image(in: frame, draw: draw)
    _ = run.image(in: frame, draw: draw)
    XCTAssertEqual(draws, 1)

    _ = run.image(in: CGRect(x: 0, y: 0, width: 180, height: 320), draw: draw)
    XCTAssertEqual(draws, 2)
  }

  func testAFrameThatDrewNothingIsNotDrawnAgain() {
    let run = FlattenedLayers(layers: [])
    var draws = 0

    XCTAssertNil(run.image(in: frame) { draws += 1; return nil })
    XCTAssertNil(run.image(in: frame) { draws += 1; return nil })
    XCTAssertEqual(draws, 1)
  }

  func testOnlyTheLatestFrameExtentsAreKept() {
    let run = FlattenedLayers(layers: [])
    var draws = 0
    let draw: () -> CIImage? = {
      draws += 1
      return CIImage(color: .red)
    }
    let extents = (0...FlattenedLayers.maxFrames).map {
      CGRect(x: 0, y: 0, width: 100 + $0, height: 100)
    }

    for extent in extents { _ = run.image(in: extent, draw: draw) }
    _ = run.image(in: extents.last!, draw: draw)
    XCTAssertEqual(draws, extents.count)

    _ = run.image(in: extents.first!, draw: draw)
    XCTAssertEqual(draws, extents.count + 1)
  }

  // MARK: - Helpers

  private func layer(
    image: EncodedImage? = nil,
    startUs: Int64 = -1,
    endUs: Int64 = -1,
    x: Int64? = 10,
    y: Int64? = 20,
    width: Double? = 100,
    height: Double? = 50,
    rotation: Double = 0,
    animations: [LayerAnimationConfig] = [],
    keyframes: [KeyframeConfig] = [],
    censor: LayerCensorConfig? = nil
  ) -> ImageLayerConfig {
    ImageLayerConfig(
      image: image ?? .bytes(png(CGColor(red: 1, green: 0, blue: 0, alpha: 1))),
      startUs: startUs,
      endUs: endUs,
      x: x,
      y: y,
      width: width,
      height: height,
      rotation: rotation,
      loop: true,
      animationOffsetUs: 0,
      animations: animations,
      censor: censor,
      keyframes: keyframes)
  }

  /// `layer` shown from `startUs` on.
  private func layer(_ layer: ImageLayerConfig, startUs: Int64) -> ImageLayerConfig {
    ImageLayerConfig(
      image: layer.image,
      startUs: startUs,
      endUs: layer.endUs,
      x: layer.x,
      y: layer.y,
      width: layer.width,
      height: layer.height,
      rotation: layer.rotation,
      loop: layer.loop,
      animationOffsetUs: layer.animationOffsetUs,
      animations: layer.animations)
  }

  private func png(_ color: CGColor, width: Int = 40, height: Int = 20) -> Data {
    encode(image(width: width, height: height) { context in
      context.setFillColor(color)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }, type: "public.png")
  }

  private func twoColorPng() -> Data {
    encode(image(width: 40, height: 20) { context in
      context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9))
      context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
      context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 0.6))
      context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
    }, type: "public.png")
  }

  private func animatedGif() -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      data, "com.compuserve.gif" as CFString, 2, nil)!
    for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
      let frame = image(width: 8, height: 8) { context in
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
      }
      CGImageDestinationAddImage(destination, frame, nil)
    }
    CGImageDestinationFinalize(destination)
    return data as Data
  }

  private func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(context)
    return context.makeImage()!
  }

  private func encode(_ image: CGImage, type: String) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
  }

  /// `image` within `frame` as RGBA bytes, rendered as the compositor renders.
  private func pixels(_ image: CIImage) -> [UInt8] {
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    let width = Int(frame.width)
    let height = Int(frame.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    context.render(
      image, toBitmap: &bytes, rowBytes: width * 4, bounds: frame, format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return bytes
  }
}
