import CoreGraphics
import CoreImage
import Foundation

/// Draws a layer's shape mask for each frame and keeps the last one, so a
/// mask that holds still between keyframes is drawn once.
///
/// A class, so `LayerPlacement` and `ImageLayer` stay `Sendable` and every
/// window a layer shows in shares one cache. The compositor may render frames
/// on several threads, hence the lock.
final class ShapeMaskRenderer: @unchecked Sendable {
  let config: ShapeMaskConfig

  private let lock = NSLock()
  private var drawn: (state: ShapeMaskState, width: Int, height: Int, image: CIImage)?

  init(config: ShapeMaskConfig) {
    self.config = config
  }

  /// The mask at [keyframeTimeUs] on the layer's keyframe timeline, as an
  /// alpha matte of [size] pixels with its extent at the origin.
  func matte(atKeyframeUs keyframeTimeUs: Int64, size: CGSize) -> CIImage {
    let state = config.state(atUs: keyframeTimeUs)
    let width = max(1, Int(size.width.rounded()))
    let height = max(1, Int(size.height.rounded()))
    lock.lock()
    defer { lock.unlock() }
    if let drawn, drawn.state == state, drawn.width == width, drawn.height == height {
      return drawn.image
    }
    let image = drawShapeMask(state, width: width, height: height)
    drawn = (state, width, height, image)
    return image
  }
}

/// The Gaussian edge goes from about 10 % to 90 % over 2.56 sigma, which is
/// the distance a mask's feather promises.
private let featherPerSigma = 2.56

/// How far beyond an image a soft shape is drawn before it is blurred, in
/// sigmas: far enough that the part of the shape outside the image still
/// blurs into it, as a blur of the whole shape does in pro_image_editor.
private let blurMarginSigmas = 3.0

/// [state] drawn into an alpha matte of [width] x [height] pixels: opaque
/// where the masked image shows, transparent where it does not, and partly
/// transparent across a soft edge.
///
/// Follows the `LayerMask.paint` of pro_image_editor, which draws the editor
/// preview, as `ShapeMaskPainter` does on Android: a hard edge is an
/// anti-aliased fill, a soft one the same fill blurred by a Gaussian of
/// `feather / 2.56`, a linear edge a straight gradient, and an inverted mask
/// everything but the shape.
func drawShapeMask(_ state: ShapeMaskState, width: Int, height: Int) -> CIImage {
  let bounds = CGRect(x: 0, y: 0, width: width, height: height)
  let featherPx = state.feather * Double(min(width, height))

  if state.shape == .linear {
    return alphaImage(width: width, height: height, margin: 0) { context in
      drawLinearEdge(state, featherPx: featherPx, width: width, height: height, in: context)
    }
  }

  let sigma = featherPx / featherPerSigma
  // Below half a pixel a blur is invisible, as Skia, which draws the
  // preview on Android, never blurs less than that.
  let margin = sigma > 0.5 ? Int((sigma * blurMarginSigmas).rounded(.up)) : 0
  let shape = shapeMaskOutline(state, width: width, height: height)
  var image = alphaImage(width: width, height: height, margin: margin) { context in
    context.addPath(shape)
    context.fillPath()
  }
  if margin > 0 {
    image = image.applyingGaussianBlur(sigma: sigma)
      .cropped(to: bounds.insetBy(dx: CGFloat(-margin), dy: CGFloat(-margin)))
  }
  if state.invert {
    // Everything but the shape, its edge as soft as the shape's own.
    image = image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: -1),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      ])
  }
  return image.cropped(to: bounds)
}

/// An alpha-only image of [width] x [height] pixels that [draw] fills in a
/// top-left coordinate space, with [margin] more pixels drawn on every side.
/// Its extent keeps the image at the origin, the margin around it.
private func alphaImage(
  width: Int, height: Int, margin: Int, draw: (CGContext) -> Void
) -> CIImage {
  let fullWidth = width + 2 * margin
  let fullHeight = height + 2 * margin
  var data = Data(count: fullWidth * fullHeight)
  data.withUnsafeMutableBytes { buffer in
    guard let base = buffer.baseAddress,
      let context = CGContext(
        data: base, width: fullWidth, height: fullHeight, bitsPerComponent: 8,
        bytesPerRow: fullWidth, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
    else { return }
    // The first row in memory is the top of the image, as `CIImage(bitmapData:)`
    // reads it, so the drawing is flipped onto it.
    context.translateBy(x: CGFloat(margin), y: CGFloat(fullHeight - margin))
    context.scaleBy(x: 1, y: -1)
    context.setShouldAntialias(true)
    context.setFillColor(gray: 1, alpha: 1)
    draw(context)
  }
  return CIImage(
    bitmapData: data, bytesPerRow: fullWidth,
    size: CGSize(width: fullWidth, height: fullHeight), format: .A8, colorSpace: nil
  ).transformed(by: CGAffineTransform(translationX: CGFloat(-margin), y: CGFloat(-margin)))
}

/// A straight edge through the centre of [state], the image showing above it
/// while unturned, softened into a gradient [featherPx] wide.
private func drawLinearEdge(
  _ state: ShapeMaskState, featherPx: Double, width: Int, height: Int, in context: CGContext
) {
  let center = CGPoint(x: state.centerX * Double(width), y: state.centerY * Double(height))
  // To the farthest corner, so the edge crosses the whole image even when the
  // centre lies outside it.
  let reach = [
    CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0), CGPoint(x: 0, y: height),
    CGPoint(x: width, y: height),
  ].map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 0

  context.saveGState()
  context.translateBy(x: center.x, y: center.y)
  context.rotate(by: CGFloat(state.rotation))
  if featherPx > 0 {
    let half = CGFloat(featherPx / 2)
    let shown: [CGFloat] = [1, 1]
    let hidden: [CGFloat] = [1, 0]
    let colors = state.invert ? [hidden, shown] : [shown, hidden]
    guard
      let gradient = CGGradient(
        colorSpace: CGColorSpaceCreateDeviceGray(),
        colorComponents: colors[0] + colors[1], locations: [0, 1], count: 2)
    else {
      context.restoreGState()
      return
    }
    context.clip(to: CGRect(x: -reach, y: -reach, width: 2 * reach, height: 2 * reach))
    context.drawLinearGradient(
      gradient, start: CGPoint(x: 0, y: -half), end: CGPoint(x: 0, y: half),
      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  } else if state.invert {
    context.fill(CGRect(x: -reach, y: 0, width: 2 * reach, height: reach))
  } else {
    context.fill(CGRect(x: -reach, y: -reach, width: 2 * reach, height: reach))
  }
  context.restoreGState()
}

/// The outline of [state]'s shape on a [width] x [height] image, in its
/// top-left pixels, mirrored and turned around its centre. Mirrors
/// `ShapeMaskGeometry` on Android and the shapes of pro_image_editor's
/// `LayerMask`.
func shapeMaskOutline(_ state: ShapeMaskState, width: Int, height: Int) -> CGPath {
  let center = CGPoint(x: state.centerX * Double(width), y: state.centerY * Double(height))
  let rect = CGRect(
    x: center.x - state.width * Double(width) / 2,
    y: center.y - state.height * Double(height) / 2,
    width: state.width * Double(width),
    height: state.height * Double(height))

  let path = CGMutablePath()
  switch state.shape {
  case .ellipse:
    path.addEllipse(in: rect)
  case .rectangle:
    let radius = CGFloat(state.cornerRadius) * min(rect.width, rect.height) / 2
    path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
  case .heart:
    addHeart(to: path, in: rect)
  case .star:
    addPolygon(unitStar, to: path, in: rect)
  case .triangle:
    addPolygon([(0.5, 0), (1, 1), (0, 1)], to: path, in: rect)
  case .diamond:
    addPolygon([(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)], to: path, in: rect)
  case .hexagon:
    addPolygon([(0.5, 0), (1, 0.25), (1, 0.75), (0.5, 1), (0, 0.75), (0, 0.25)], to: path, in: rect)
  case .speechBubble:
    addSpeechBubble(to: path, in: rect)
  case .linear:
    path.addRect(rect)
  }

  var place = CGAffineTransform(translationX: center.x, y: center.y)
    .rotated(by: CGFloat(state.rotation))
  if state.mirrored { place = place.scaledBy(x: -1, y: 1) }
  place = place.translatedBy(x: -center.x, y: -center.y)
  return path.copy(using: &place) ?? path
}

/// The corners of a five-pointed star, a point at the top, fitted to a unit
/// box: the inner corners at a little under half the radius of the points, as
/// on the Material Design star, and the box spanning the points.
let unitStar: [(Double, Double)] = {
  let innerRadius = 0.455
  let corners = (0..<10).map { i -> (Double, Double) in
    let angle = -Double.pi / 2 + Double(i) * Double.pi / 5
    let radius = i % 2 == 0 ? 1 : innerRadius
    return (cos(angle) * radius, sin(angle) * radius)
  }
  // The points reach the top and both sides of the circle around the star,
  // but the two at the bottom stop short of it.
  let left = corners[8].0
  let top = corners[0].1
  let right = corners[2].0
  let bottom = corners[4].1
  return corners.map { ((($0.0 - left) / (right - left)), (($0.1 - top) / (bottom - top))) }
}()

private func addPolygon(_ corners: [(Double, Double)], to path: CGMutablePath, in rect: CGRect) {
  path.addLines(
    between: corners.map {
      CGPoint(x: rect.minX + $0.0 * rect.width, y: rect.minY + $0.1 * rect.height)
    })
  path.closeSubpath()
}

/// The Material Design heart (24 dp `favorite` icon), fitted to [rect].
private func addHeart(to path: CGMutablePath, in rect: CGRect) {
  func p(_ u: Double, _ v: Double) -> CGPoint {
    CGPoint(x: rect.minX + u * rect.width, y: rect.minY + v * rect.height)
  }
  path.move(to: p(0.5, 1))
  path.addLine(to: p(0.4275, 0.92807))
  path.addCurve(to: p(0, 0.29973), control1: p(0.17, 0.67357), control2: p(0, 0.50572))
  path.addCurve(to: p(0.275, 0), control1: p(0, 0.13188), control2: p(0.121, 0))
  path.addCurve(to: p(0.5, 0.1139), control1: p(0.362, 0), control2: p(0.4455, 0.04414))
  path.addCurve(to: p(0.725, 0), control1: p(0.5545, 0.04414), control2: p(0.638, 0))
  path.addCurve(to: p(1, 0.29973), control1: p(0.879, 0), control2: p(1, 0.13188))
  path.addCurve(to: p(0.5725, 0.92861), control1: p(1, 0.50572), control2: p(0.83, 0.67357))
  path.closeSubpath()
}

/// A speech bubble filling [rect]: a body with round corners over its top
/// four fifths, and below it a tail from the body's bottom edge, near its left
/// end, down to the bottom of [rect]. Built at [rect]'s own size, so the
/// corners stay round when the box is not square.
private func addSpeechBubble(to path: CGMutablePath, in rect: CGRect) {
  let w = rect.width
  let h = rect.height
  let bodyBottom = h * 0.8
  // At most a fifth of the body's width, so a corner never reaches the tail.
  let r = min(w, bodyBottom) * 0.2
  let l = rect.minX
  let t = rect.minY
  // Angles grow clockwise in these top-left coordinates.
  path.move(to: CGPoint(x: l + r, y: t))
  path.addLine(to: CGPoint(x: l + w - r, y: t))
  path.addRelativeArc(
    center: CGPoint(x: l + w - r, y: t + r), radius: r, startAngle: -.pi / 2, delta: .pi / 2)
  path.addLine(to: CGPoint(x: l + w, y: t + bodyBottom - r))
  path.addRelativeArc(
    center: CGPoint(x: l + w - r, y: t + bodyBottom - r), radius: r, startAngle: 0,
    delta: .pi / 2)
  path.addLine(to: CGPoint(x: l + w * 0.42, y: t + bodyBottom))
  path.addLine(to: CGPoint(x: l + w * 0.12, y: t + h))
  path.addLine(to: CGPoint(x: l + w * 0.2, y: t + bodyBottom))
  path.addLine(to: CGPoint(x: l + r, y: t + bodyBottom))
  path.addRelativeArc(
    center: CGPoint(x: l + r, y: t + bodyBottom - r), radius: r, startAngle: .pi / 2,
    delta: .pi / 2)
  path.addLine(to: CGPoint(x: l, y: t + r))
  path.addRelativeArc(
    center: CGPoint(x: l + r, y: t + r), radius: r, startAngle: .pi, delta: .pi / 2)
  path.closeSubpath()
}
