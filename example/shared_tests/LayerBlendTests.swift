import CoreImage
import Foundation
import ImageIO
import XCTest

@testable import pro_video_editor

// Compiled into *both* the iOS and the macOS RunnerTests target (referenced
// from each project as ../shared_tests/…), like FlattenedLayersTests.swift:
// the compositor is shared Darwin code.

/// A layer's blend mode combines it with the picture beneath it. The render
/// has to produce what a Flutter preview painting the layer with the same
/// `BlendMode` shows, so the expected values are the W3C formulas Flutter
/// implements, checked against pixels Flutter painted.
final class LayerBlendTests: XCTestCase {
  private let frame = CGRect(x: 0, y: 0, width: 8, height: 8)

  // MARK: - The formulas

  func testEveryModeBlendsAsFlutterPaintsIt() {
    // Painted by Flutter (Skia and Impeller): the color 0x60A020 at full and
    // at half opacity over the backdrops 0x8040C0 and 0x2080E0.
    let painted: [(backdrop: [Int], opacity: Double, mode: LayerBlendMode, rgb: [Int])] = [
      ([0x80, 0x40, 0xC0], 1, .normal, [96, 160, 32]),
      ([0x80, 0x40, 0xC0], 1, .multiply, [48, 40, 24]),
      ([0x80, 0x40, 0xC0], 1, .screen, [176, 184, 200]),
      ([0x80, 0x40, 0xC0], 1, .overlay, [97, 80, 145]),
      ([0x80, 0x40, 0xC0], 1, .softLight, [112, 80, 156]),
      ([0x80, 0x40, 0xC0], 1, .darken, [96, 64, 32]),
      ([0x80, 0x40, 0xC0], 1, .lighten, [128, 160, 192]),
      ([0x80, 0x40, 0xC0], 1, .add, [224, 224, 224]),
      ([0x80, 0x40, 0xC0], 1, .difference, [32, 96, 160]),
      ([0x80, 0x40, 0xC0], 0.5, .multiply, [88, 52, 108]),
      ([0x80, 0x40, 0xC0], 0.5, .screen, [152, 124, 196]),
      ([0x80, 0x40, 0xC0], 0.5, .add, [176, 144, 208]),
      ([0x20, 0x80, 0xE0], 1, .overlay, [24, 160, 201]),
      ([0x20, 0x80, 0xE0], 1, .softLight, [25, 141, 204]),
      ([0x20, 0x80, 0xE0], 1, .add, [128, 255, 255]),
      ([0x20, 0x80, 0xE0], 0.5, .overlay, [28, 144, 212]),
      ([0x20, 0x80, 0xE0], 0.5, .softLight, [28, 135, 214]),
      ([0x20, 0x80, 0xE0], 0.5, .difference, [48, 79, 208]),
    ]
    for row in painted {
      let layer = solid(byteColor([0x60, 0xA0, 0x20]), alpha: row.opacity)
      let blended = blendLayer(layer, over: solid(byteColor(row.backdrop)), mode: row.mode)

      let pixel = rgba8(blended)
      for channel in 0..<3 {
        XCTAssertEqual(
          Int(pixel[channel]), row.rgb[channel], accuracy: 1,
          "\(row.mode) at \(row.opacity) over \(row.backdrop), channel \(channel)")
      }
      XCTAssertEqual(pixel[3], 255)
    }
  }

  func testEveryModeFollowsTheW3CFormulaForAnyAlpha() {
    var generator = SeededGenerator(seed: 7)
    for mode in LayerBlendMode.allCases {
      for _ in 0..<64 {
        let source = randomColor(&generator)
        let backdrop = randomColor(&generator)
        let alpha = Double.random(in: 0...1, using: &generator)
        let backdropAlpha = [1, Double.random(in: 0...1, using: &generator)].randomElement(
          using: &generator)!

        let blended = blendLayer(
          solid(source, alpha: alpha), over: solid(backdrop, alpha: backdropAlpha), mode: mode)

        let expected = w3c(
          mode, source: source, alpha: alpha, backdrop: backdrop, backdropAlpha: backdropAlpha)
        let actual = rgbaFloat(blended)
        for channel in 0..<4 {
          XCTAssertEqual(
            Double(actual[channel]), expected[channel], accuracy: 0.0005,
            "\(mode): \(source) at \(alpha) over \(backdrop) at \(backdropAlpha)")
        }
      }
    }
  }

  func testATransparentLayerLeavesThePictureAsItIs() {
    let backdrop = solid([0.3, 0.6, 0.9])
    for mode in LayerBlendMode.allCases {
      let blended = blendLayer(solid([1, 0.5, 0], alpha: 0), over: backdrop, mode: mode)

      XCTAssertEqual(rgba8(blended), rgba8(backdrop), "\(mode)")
    }
  }

  // MARK: - Image layers

  func testABlendedLayerIsNotDrawnWithTheStaticLayersAroundIt() {
    let layers = [layer(), layer(blendMode: .multiply), layer()]

    XCTAssertEqual(staticLayerRunLength(layers, from: 0), 1)
    XCTAssertEqual(staticLayerRunLength(layers, from: 1), 0)

    let compositor = VideoCompositor()
    compositor.setOverlayImageLayers(from: [layer(), layer(), layer(blendMode: .screen)])
    XCTAssertEqual(compositor.overlayImageLayers.count, 2)
    XCTAssertNotNil(compositor.overlayImageLayers[0].flattened)
    XCTAssertEqual(compositor.overlayImageLayers[1].blendMode, .screen)
  }

  func testAnImageLayerBlendsWithThePictureBeneathIt() {
    let compositor = VideoCompositor()
    // Over the left half of the frame only.
    compositor.setOverlayImageLayers(from: [
      layer(color: [0x60, 0xA0, 0x20], x: 0, width: 4, blendMode: .multiply)
    ])
    let backdrop = solid(byteColor([0x80, 0x40, 0xC0]))

    let drawn = compositor.drawImageLayer(
      compositor.overlayImageLayers[0], over: backdrop, imageRect: frame, currentTimeUs: 0)

    let inside = rgba8(drawn, at: CGPoint(x: 1, y: 4))
    XCTAssertEqual(Int(inside[0]), 48, accuracy: 1)
    XCTAssertEqual(Int(inside[1]), 40, accuracy: 1)
    XCTAssertEqual(Int(inside[2]), 24, accuracy: 1)
    XCTAssertEqual(rgba8(drawn, at: CGPoint(x: 6, y: 4)), [0x80, 0x40, 0xC0, 255])
  }

  func testALayerUntilTheEndThatAnimatesOutKeepsItsMode() {
    // Its end is resolved to the composition's length on a copy of it.
    let fadeOut = LayerAnimationConfig(
      type: "fade", phase: "animateOut", durationUs: 500_000, curve: "linear",
      slideDirection: nil, slideFrom: nil, scaleFrom: nil)
    let screened = ImageLayerConfig(
      image: .bytes(encodedPng(color: [255, 0, 0])), startUs: -1, endUs: -1, x: 0, y: 0,
      width: 8, height: 8, rotation: 0, loop: true, animationOffsetUs: 0,
      animations: [fadeOut], blendMode: .screen)

    let resolved = resolveOpenEndedOutAnimations([screened], totalDurationUs: 2_000_000)

    XCTAssertEqual(resolved[0].endUs, 2_000_000)
    XCTAssertEqual(resolved[0].blendMode, .screen)
  }

  // MARK: - Arguments

  func testTheModeIsReadByName() {
    let png = encodedPng(color: [255, 0, 0])
    func imageLayer(_ mode: Any?) -> ImageLayerConfig? {
      var args: [String: Any] = ["imageData": png]
      if let mode { args["blendMode"] = mode }
      return ImageLayerConfig.fromArguments(args)
    }

    XCTAssertEqual(imageLayer("softLight")?.blendMode, .softLight)
    XCTAssertEqual(imageLayer(nil)?.blendMode, .normal)
    XCTAssertEqual(imageLayer("colorBurn")?.blendMode, .normal)

    let clip: [String: Any] = ["inputPath": "/tmp/clip.mp4"]
    XCTAssertEqual(
      LayerConfig.fromArguments(["clips": [clip], "blendMode": "difference"])?.blendMode,
      .difference)
    XCTAssertEqual(LayerConfig.fromArguments(["clips": [clip]])?.blendMode, .normal)
  }

  // MARK: - Helpers

  private func layer(
    color: [Int] = [255, 0, 0],
    x: Int64 = 0,
    width: Double = 8,
    blendMode: LayerBlendMode = .normal
  ) -> ImageLayerConfig {
    ImageLayerConfig(
      image: .bytes(encodedPng(color: color)),
      startUs: -1,
      endUs: -1,
      x: x,
      y: 0,
      width: width,
      height: 8,
      rotation: 0,
      loop: true,
      animationOffsetUs: 0,
      animations: [],
      blendMode: blendMode)
  }

  private func byteColor(_ rgb: [Int]) -> [Double] { rgb.map { Double($0) / 255 } }

  private func solid(_ rgb: [Double], alpha: Double = 1) -> CIImage {
    CIImage(color: CIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha))
      .cropped(to: frame)
  }

  private func randomColor(_ generator: inout SeededGenerator) -> [Double] {
    (0..<3).map { _ in Double.random(in: 0...1, using: &generator) }
  }

  /// The W3C separable blend, composited with the general source-over
  /// alpha, as premultiplied RGBA; `add` is the premultiplied plus.
  private func w3c(
    _ mode: LayerBlendMode, source: [Double], alpha: Double, backdrop: [Double],
    backdropAlpha: Double
  ) -> [Double] {
    var result: [Double] = []
    for i in 0..<3 {
      if mode == .add {
        result.append(min(1, alpha * source[i] + backdropAlpha * backdrop[i]))
        continue
      }
      let onlySource: Double = alpha * (1 - backdropAlpha) * source[i]
      let both: Double = alpha * backdropAlpha * Self.blend(mode, backdrop[i], source[i])
      let onlyBackdrop: Double = (1 - alpha) * backdropAlpha * backdrop[i]
      result.append(onlySource + both + onlyBackdrop)
    }
    let outAlpha: Double =
      mode == .add ? min(1, alpha + backdropAlpha) : alpha + backdropAlpha * (1 - alpha)
    return result + [outAlpha]
  }

  private static func blend(_ mode: LayerBlendMode, _ cb: Double, _ cs: Double) -> Double {
    switch mode {
    case .normal, .add: return cs
    case .multiply: return cb * cs
    case .screen: return cb + cs - cb * cs
    case .overlay: return cb <= 0.5 ? 2 * cb * cs : 1 - 2 * (1 - cb) * (1 - cs)
    case .softLight:
      let d = cb <= 0.25 ? ((16 * cb - 12) * cb + 4) * cb : cb.squareRoot()
      return cs <= 0.5 ? cb - (1 - 2 * cs) * cb * (1 - cb) : cb + (2 * cs - 1) * (d - cb)
    case .darken: return min(cb, cs)
    case .lighten: return max(cb, cs)
    case .difference: return abs(cb - cs)
    }
  }

  private func rgba8(_ image: CIImage, at point: CGPoint = CGPoint(x: 4, y: 4)) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    context.render(
      image, toBitmap: &bytes, rowBytes: 4,
      bounds: CGRect(x: point.x, y: frame.height - 1 - point.y, width: 1, height: 1),
      format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return bytes
  }

  private func rgbaFloat(_ image: CIImage) -> [Float] {
    var values = [Float](repeating: 0, count: 4)
    context.render(
      image, toBitmap: &values, rowBytes: 16, bounds: CGRect(x: 4, y: 4, width: 1, height: 1),
      format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return values
  }

  private let context = CIContext(options: [.workingColorSpace: NSNull()])

  private func encodedPng(color: [Int]) -> Data {
    let context = CGContext(
      data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // In sRGB, the context's own space: `CGColor(red:green:blue:alpha:)` is
    // Generic RGB, which the fill would convert to other values.
    context.setFillColor(
      CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: color.map { CGFloat($0) / 255 } + [1])!)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
  }
}

/// A small deterministic generator, so a failure reproduces.
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}
