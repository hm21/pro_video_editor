import CoreGraphics
import CoreImage
import Foundation

// The shapes of an audio visualizer, computed exactly as the Dart
// `audioVisualizerShapes` and the Kotlin `audioVisualizerShapes` compute
// them, so the editor's preview and the export draw the same thing. Change
// all three together.

/// How much of its slot a bar fills; Dart `audioVisualizerBarFill`.
let audioVisualizerBarFill = 0.7
/// The level a wave band never drops below; Dart `audioVisualizerWaveMinLevel`.
let audioVisualizerWaveMinLevel = 0.04
/// The ring's radius against the box's circle; Dart
/// `audioVisualizerCircleInnerRadius`.
let audioVisualizerCircleInnerRadius = 0.5
/// How much of its share of the ring a bar fills; Dart
/// `audioVisualizerCircleBarFill`.
let audioVisualizerCircleBarFill = 0.6

/// `level` held to 0–1, with NaN counted as silent, as the Dart
/// `audioVisualizerUnitLevel` reads it.
func audioVisualizerUnitLevel(_ level: Float) -> Double {
  level.isNaN ? 0 : min(1, max(0, Double(level)))
}

/// A rounded bar: a box with fully rounded corners of `radius`, turned
/// `rotation` radians clockwise about (`pivotX`, `pivotY`) of the layer's box,
/// its own coordinates measured from that point.
struct AudioVisualizerBar: Equatable {
  var left: Double
  var top: Double
  var right: Double
  var bottom: Double
  var radius: Double
  var pivotX: Double = 0
  var pivotY: Double = 0
  var rotation: Double = 0
}

/// The shapes one set of levels fills: `bars`, or the closed outline `wave` —
/// a start point followed by cubic Bézier curves of six values each.
struct AudioVisualizerShapes {
  var bars: [AudioVisualizerBar] = []
  var wave: [Double]? = nil
}

/// The shapes `style` draws for `levels`, one per band from 0 to 1, in a box
/// of `width` by `height` whose top-left corner is the origin. `barFill` is
/// how much of its share a bar fills, `nil` for the style's own.
func audioVisualizerShapes(
  style: LayerAudioVisualizerConfig.Style, width: Double, height: Double, levels: [Float],
  barFill: Double? = nil
) -> AudioVisualizerShapes {
  let count = levels.count
  guard count > 0, width > 0, height > 0 else { return AudioVisualizerShapes() }
  func level(_ band: Int) -> Double { audioVisualizerUnitLevel(levels[band]) }

  switch style {
  case .bars, .mirroredBars:
    let slot = width / Double(count)
    let barWidth = slot * (barFill ?? audioVisualizerBarFill)
    // A silent bar is a dot as wide as the bar.
    let minHeight = min(barWidth, height)
    return AudioVisualizerShapes(
      bars: (0..<count).map { band in
        let barHeight = min(height, max(minHeight, level(band) * height))
        let left = Double(band) * slot + (slot - barWidth) / 2
        let top = style == .mirroredBars ? (height - barHeight) / 2 : height - barHeight
        return AudioVisualizerBar(
          left: left, top: top, right: left + barWidth, bottom: top + barHeight,
          radius: min(barWidth, barHeight) / 2)
      })
  case .circle:
    let radius = min(width, height) / 2
    let bars = count * 2
    let ring = radius * audioVisualizerCircleInnerRadius
    let barWidth = min(
      2 * Double.pi * ring / Double(bars) * (barFill ?? audioVisualizerCircleBarFill),
      (radius - ring) / 2)
    let maxLength = max(0, radius - ring - barWidth)
    return AudioVisualizerShapes(
      bars: (0..<bars).map { bar in
        // The bands run from the top down both sides of the ring.
        let band = bar < count ? bar : bars - 1 - bar
        return AudioVisualizerBar(
          left: -barWidth / 2,
          top: -(ring + barWidth + level(band) * maxLength),
          right: barWidth / 2,
          bottom: -ring,
          radius: barWidth / 2,
          pivotX: width / 2,
          pivotY: height / 2,
          rotation: 2 * Double.pi * (Double(bar) + 0.5) / Double(bars))
      })
  case .wave:
    return AudioVisualizerShapes(wave: audioVisualizerWaveOutline(width, height, levels))
  }
}

/// The outline of a wave: a Catmull-Rom curve through one point per band along
/// the top, mirrored along the bottom.
private func audioVisualizerWaveOutline(
  _ width: Double, _ height: Double, _ levels: [Float]
) -> [Double] {
  let count = levels.count
  let middle = height / 2
  // Each point's x and its distance from the middle line, with a point of no
  // height at either edge so the wave tapers there.
  var xs = [Double](repeating: 0, count: count + 2)
  var amplitudes = [Double](repeating: 0, count: count + 2)
  xs[count + 1] = width
  for band in 0..<count {
    xs[band + 1] = (Double(band) + 0.5) * width / Double(count)
    amplitudes[band + 1] =
      max(audioVisualizerWaveMinLevel, audioVisualizerUnitLevel(levels[band])) * middle
  }

  let last = count + 1
  // The control points of the curve from point i to point i + 1, kept between
  // the middle line and the edge of the box, so the curve can neither cross
  // the middle line nor leave the box.
  func controls(_ i: Int) -> (Double, Double, Double, Double) {
    let before = max(0, i - 1)
    let after = min(last, i + 2)
    return (
      xs[i] + (xs[i + 1] - xs[before]) / 6,
      min(middle, max(0, amplitudes[i] + (amplitudes[i + 1] - amplitudes[before]) / 6)),
      xs[i + 1] - (xs[after] - xs[i]) / 6,
      min(middle, max(0, amplitudes[i + 1] - (amplitudes[after] - amplitudes[i]) / 6))
    )
  }

  var outline: [Double] = [0, middle]
  outline.reserveCapacity(2 + last * 12)
  // Along the top, left to right.
  for i in 0..<last {
    let (c1x, c1a, c2x, c2a) = controls(i)
    outline += [c1x, middle - c1a, c2x, middle - c2a, xs[i + 1], middle - amplitudes[i + 1]]
  }
  // Back along the bottom, right to left, through the same control points.
  for i in stride(from: last - 1, through: 0, by: -1) {
    let (c1x, c1a, c2x, c2a) = controls(i)
    outline += [c2x, middle + c2a, c1x, middle + c1a, xs[i], middle + amplitudes[i]]
  }
  return outline
}

/// Draws an audio visualizer layer for each frame, from the levels at that
/// frame's time, into an image the compositor places like a decoded one.
///
/// Reused across frames; the image of the last frame it drew is kept, since
/// the compositor may ask for the same frame twice.
final class AudioVisualizerRenderer {
  /// The largest side of a raster, in pixels: a layer pinched far past the
  /// frame is drawn at less density rather than at any size.
  static let maxRasterSide: CGFloat = 4096

  private let config: LayerAudioVisualizerConfig
  /// How many raster pixels a pixel of the layer's box is drawn at: its
  /// largest keyframe scale, so a layer keyframes grow stays sharp.
  private let rasterScale: CGFloat
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
  private var levels: [Float]
  private var last: (timeUs: Int64, box: CGSize, image: CIImage)?
  private let lock = NSLock()

  init(config: LayerAudioVisualizerConfig, rasterScale: CGFloat) {
    self.config = config
    self.rasterScale = max(1, rasterScale)
    self.levels = [Float](repeating: 0, count: config.bandCount)
  }

  /// The visualizer at `timeUs` on the rendered video, drawn into a box of
  /// `box` frame pixels, as an image at the origin whose extent is its
  /// raster; the caller scales it to the box.
  func image(atUs timeUs: Int64, box: CGSize) -> CIImage {
    lock.lock()
    defer { lock.unlock() }
    if let last, last.timeUs == timeUs, last.box == box { return last.image }

    var scale = rasterScale
    let largest = max(box.width, box.height) * scale
    if largest > Self.maxRasterSide { scale *= Self.maxRasterSide / largest }
    let pixelWidth = max(1, Int((box.width * scale).rounded()))
    let pixelHeight = max(1, Int((box.height * scale).rounded()))
    guard box.width > 0, box.height > 0,
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      return CIImage.empty()
    }
    // Top-left origin, in the box's own units, as the other renderers draw.
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(
      x: CGFloat(pixelWidth) / box.width, y: -CGFloat(pixelHeight) / box.height)
    context.setShouldAntialias(true)
    context.setFillColor(fillColor)

    config.levels(atUs: timeUs, into: &levels)
    draw(
      audioVisualizerShapes(
        style: config.style, width: Double(box.width), height: Double(box.height),
        levels: levels, barFill: config.barFill),
      in: context)

    let image = context.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    last = (timeUs, box, image)
    return image
  }

  private var fillColor: CGColor {
    let argb = config.color
    let components: [CGFloat] = [
      CGFloat((argb >> 16) & 0xFF) / 255,
      CGFloat((argb >> 8) & 0xFF) / 255,
      CGFloat(argb & 0xFF) / 255,
      CGFloat((argb >> 24) & 0xFF) / 255,
    ]
    return CGColor(colorSpace: colorSpace, components: components)
      ?? CGColor(red: components[0], green: components[1], blue: components[2], alpha: components[3])
  }

  private func draw(_ shapes: AudioVisualizerShapes, in context: CGContext) {
    for bar in shapes.bars {
      let rect = CGRect(
        x: bar.left, y: bar.top, width: bar.right - bar.left, height: bar.bottom - bar.top)
      // Rounding can leave the radius a hair over half the side, which
      // CGPath does not accept.
      let radius = max(0, min(CGFloat(bar.radius), rect.width / 2, rect.height / 2))
      context.saveGState()
      context.translateBy(x: bar.pivotX, y: bar.pivotY)
      // Clockwise, since the context is flipped to a top-left origin.
      context.rotate(by: bar.rotation)
      context.addPath(
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
      context.fillPath()
      context.restoreGState()
    }
    guard let wave = shapes.wave, wave.count >= 2 else { return }
    let path = CGMutablePath()
    path.move(to: CGPoint(x: wave[0], y: wave[1]))
    var i = 2
    while i + 5 < wave.count {
      path.addCurve(
        to: CGPoint(x: wave[i + 4], y: wave[i + 5]),
        control1: CGPoint(x: wave[i], y: wave[i + 1]),
        control2: CGPoint(x: wave[i + 2], y: wave[i + 3]))
      i += 6
    }
    path.closeSubpath()
    context.addPath(path)
    context.fillPath()
  }
}
