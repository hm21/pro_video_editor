import CoreImage
import Foundation

/// Core Image drawing for the overlap transitions that move, blur or flash the
/// picture — zoom in and out, spin, whip pan, blur, glitch, flash, iris and
/// stretch.
///
/// `ClipTransitionRenderer` drives dissolve, slide, push and wipe with layer
/// instruction ramps and hands every type ``handles(_:)`` reports to
/// `ClipTransitionCompositor`, which draws each frame with ``compose``.
/// `ClipTransitionType` in Dart specifies what each transition shows; Android
/// draws the same on I420 frames in `ClipTransitionEffects.kt`, which shares
/// the constants below. Only stock Core Image filters are used, as for the
/// video effects: a custom kernel would need Metal libraries older iPhones
/// lack.
internal enum ClipTransitionEffects {

  /// How far zoomIn zooms into the outgoing clip, and zoomOut out of the
  /// incoming one.
  static let zoomAmount = 0.5
  /// Progress by which zoomIn's incoming clip is fully opaque.
  static let zoomFadeInEnd = 0.4
  /// Progress from which zoomOut's outgoing clip fades out.
  static let zoomFadeOutStart = 0.6
  /// Progress window in which spin changes clip.
  static let spinSwapStart = 0.35
  static let spinSwapEnd = 0.65
  /// whipPan's motion blur at mid-transition, as a fraction of the frame
  /// along its motion.
  static let whipBlurLength = 0.25
  /// blur's Gaussian sigma at mid-transition, as a fraction of the frame's
  /// shorter side.
  static let blurSigma = 0.05
  /// Progress window in which blur changes clip.
  static let blurSwapStart = 0.3
  static let blurSwapEnd = 0.7
  /// Horizontal slices the glitch moves.
  static let glitchBandCount = 16
  /// How often per second the glitch pattern changes.
  static let glitchRateHz = 15.0
  /// Chance that a slice moves, at full glitch strength.
  static let glitchBandChance = 0.7
  /// Chance that a moved slice shows the other clip.
  static let glitchSwapChance = 0.4
  /// A slice's largest move, as a fraction of the frame width.
  static let glitchMaxShift = 0.12
  /// How far red and blue split apart, as a fraction of the frame width.
  static let glitchSplit = 0.02
  /// Progress window in which flash changes clip, hidden under its peak.
  static let flashSwapStart = 0.45
  static let flashSwapEnd = 0.55
  /// Sharpness of the flash: its strength is the triangle 0 → 1 → 0 to this
  /// power.
  static let flashPower = 4.0
  /// Width of iris's soft circle edge, in frame pixels.
  static let irisEdge = 2.0

  /// Offsets ``glitchHash`` so slice 0 of pattern 0 does not hash to 0.
  private static let glitchSeed: UInt32 = 0x9E37_79B9

  private static let types: Set<String> = [
    "zoomIn", "zoomOut", "spin", "whipPan", "blur", "glitch", "flash", "iris", "stretch",
  ]

  /// Whether ``compose`` draws `type`.
  static func handles(_ type: String) -> Bool { types.contains(type) }

  /// One frame of the transition from `outgoing` into `incoming`, both upright
  /// frames with the extent `(0, 0, size)`.
  ///
  /// - Parameters:
  ///   - progress: Eased progress, 0 = only `outgoing`, 1 = only `incoming`;
  ///     an elastic curve overshoots it.
  ///   - linearProgress: Progress before easing, 0...1. The glitch pattern
  ///     changes with it, so it keeps its pace whatever the curve.
  ///   - durationUs: Output duration of the transition.
  static func compose(
    type: String, direction: String,
    outgoing a: CIImage, incoming b: CIImage, size: CGSize,
    progress p: Double, linearProgress: Double, durationUs: Int64
  ) -> CIImage {
    let frame = CGRect(origin: .zero, size: size)
    let c = min(max(p, 0), 1)
    let result: CIImage
    switch type {
    case "zoomIn":
      result = layered(
        bottom: about(a, size: size, scale: 1 + zoomAmount * p, clampEdges: true) ?? a,
        top: about(b, size: size, scale: p, clampEdges: false),
        topOpacity: smoothstep(0, zoomFadeInEnd, c))
    case "zoomOut":
      result = layered(
        bottom: about(b, size: size, scale: 1 + zoomAmount * (1 - p), clampEdges: true) ?? b,
        top: about(a, size: size, scale: 1 - p, clampEdges: false),
        topOpacity: 1 - smoothstep(zoomFadeOutStart, 1, c))
    case "spin":
      let outgoingAngle = Double.pi * p
      let incomingAngle = Double.pi * (p - 1)
      result = layered(
        bottom: about(
          a, size: size, scale: coverScale(size, angle: outgoingAngle), angle: outgoingAngle,
          clampEdges: true) ?? a,
        top: about(
          b, size: size, scale: coverScale(size, angle: incomingAngle), angle: incomingAngle,
          clampEdges: true),
        topOpacity: smoothstep(spinSwapStart, spinSwapEnd, c))
    case "whipPan":
      let horizontal = direction == "left" || direction == "right"
      let length =
        whipBlurLength * Double(horizontal ? size.width : size.height) * sin(Double.pi * c)
      result = motionBlurred(
        pushed(a, b, size: size, p: p, direction: direction),
        horizontal: horizontal, length: length, frame: frame)
    case "blur":
      let sigma = blurSigma * Double(min(size.width, size.height)) * sin(Double.pi * c)
      let mixed = layered(bottom: a, top: b, topOpacity: smoothstep(blurSwapStart, blurSwapEnd, c))
      result =
        sigma < 0.5
        ? mixed : mixed.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: frame)
    case "glitch":
      result = glitched(
        a, b, size: size, c: c,
        phase: glitchPhase(linearProgress: linearProgress, durationUs: durationUs))
    case "flash":
      result = brightened(
        layered(bottom: a, top: b, topOpacity: smoothstep(flashSwapStart, flashSwapEnd, c)),
        by: flashStrength(c))
    case "iris":
      result = irised(a, b, size: size, p: p)
    case "stretch":
      result = stretched(a, b, size: size, p: p, direction: direction)
    default:
      result = a
    }
    return result.cropped(to: frame)
  }

  // MARK: - Shared math (mirrored in ClipTransitionEffects.kt)

  /// Hermite smoothstep of `x` between `edge0` and `edge1`.
  static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
  }

  /// How much a frame of `size` turned by `angle` about its center must be
  /// scaled to still cover the whole frame.
  static func coverScale(_ size: CGSize, angle: Double) -> Double {
    let w = Double(size.width)
    let h = Double(size.height)
    let c = abs(cos(angle))
    let s = abs(sin(angle))
    return max((w * c + h * s) / w, (w * s + h * c) / h)
  }

  /// The flash's strength at clamped progress `c`: 0 at either end, 1 at the
  /// midpoint.
  static func flashStrength(_ c: Double) -> Double {
    pow(1 - abs(2 * c - 1), flashPower)
  }

  /// A deterministic value in 0..<1 for slice `band` in glitch pattern
  /// `phase`; `salt` picks one of several independent values. Wrapping
  /// 32-bit math, exactly as Android's `Int` math, so both platforms glitch
  /// alike.
  static func glitchHash(band: Int, phase: Int, salt: Int) -> Double {
    var h =
      UInt32(truncatingIfNeeded: band) &* 374_761_393
      &+ UInt32(truncatingIfNeeded: phase) &* 668_265_263
      &+ UInt32(truncatingIfNeeded: salt) &* 1_442_695_041
      &+ glitchSeed
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Double(h) / 4_294_967_296.0
  }

  /// One slice of the glitch: how far it moves right and which clip it shows.
  struct GlitchBand: Equatable {
    let shift: Int
    let showsIncoming: Bool
  }

  /// The glitch's slices at clamped progress `c` in pattern `phase` for a
  /// frame `width` pixels wide.
  static func glitchBands(c: Double, phase: Int, width: Int) -> [GlitchBand] {
    let strength = sin(Double.pi * c)
    let cut = c >= 0.5
    return (0..<glitchBandCount).map { band in
      guard glitchHash(band: band, phase: phase, salt: 0) < glitchBandChance * strength else {
        return GlitchBand(shift: 0, showsIncoming: cut)
      }
      let shift = Int(
        ((glitchHash(band: band, phase: phase, salt: 1) * 2 - 1)
          * glitchMaxShift * strength * Double(width)).rounded())
      let swaps = glitchHash(band: band, phase: phase, salt: 2) < glitchSwapChance
      return GlitchBand(shift: shift, showsIncoming: swaps ? !cut : cut)
    }
  }

  /// The glitch pattern shown at `linearProgress` of a transition
  /// `durationUs` long.
  static func glitchPhase(linearProgress: Double, durationUs: Int64) -> Int {
    Int((linearProgress * Double(durationUs) / 1_000_000 * glitchRateHz).rounded(.down))
  }

  /// How far the glitch splits red and blue apart at clamped progress `c`.
  static func glitchSplitPixels(c: Double, width: Int) -> Int {
    Int((glitchSplit * sin(Double.pi * c) * Double(width)).rounded())
  }

  // MARK: - Layers

  /// `image` scaled by `scale` and turned clockwise by `angle` radians about
  /// the frame center, its edges repeated beyond the frame when `clampEdges`;
  /// nil when `scale` leaves nothing to draw.
  private static func about(
    _ image: CIImage, size: CGSize, scale: Double, angle: Double = 0, clampEdges: Bool
  ) -> CIImage? {
    guard scale > 1e-6 else { return nil }
    let cx = size.width / 2
    let cy = size.height / 2
    // Core Image's y axis points up, so a clockwise turn is a negative angle.
    let transform = CGAffineTransform(translationX: -cx, y: -cy)
      .concatenating(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
      .concatenating(CGAffineTransform(rotationAngle: CGFloat(-angle)))
      .concatenating(CGAffineTransform(translationX: cx, y: cy))
    let source = clampEdges ? image.clampedToExtent() : image
    return source.transformed(by: transform).cropped(to: CGRect(origin: .zero, size: size))
  }

  /// `top` at `opacity` over `bottom`.
  private static func layered(bottom: CIImage, top: CIImage?, topOpacity: Double) -> CIImage {
    guard let top, topOpacity > 0 else { return bottom }
    if topOpacity >= 1 { return top.composited(over: bottom) }
    return withOpacity(top, topOpacity).composited(over: bottom)
  }

  /// `image` at `opacity`. Only alpha is scaled: `CIColorMatrix` works on
  /// unpremultiplied color and premultiplies its result by the new alpha.
  private static func withOpacity(_ image: CIImage, _ opacity: Double) -> CIImage {
    image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
      ])
  }

  /// Both frames moving together toward `direction` by `p` of the frame, the
  /// incoming one following the outgoing one in.
  private static func pushed(
    _ a: CIImage, _ b: CIImage, size: CGSize, p: Double, direction: String
  ) -> CIImage {
    let w = size.width
    let h = size.height
    let move = CGFloat(p)
    // Moves in top-origin terms; Core Image's y axis points up.
    let (outgoing, incoming): (CGPoint, CGPoint) =
      switch direction {
      case "right": (CGPoint(x: move * w, y: 0), CGPoint(x: (move - 1) * w, y: 0))
      case "up": (CGPoint(x: 0, y: -move * h), CGPoint(x: 0, y: (1 - move) * h))
      case "down": (CGPoint(x: 0, y: move * h), CGPoint(x: 0, y: (move - 1) * h))
      default: (CGPoint(x: -move * w, y: 0), CGPoint(x: (1 - move) * w, y: 0))
      }
    // The outgoing frame's edge repeats under the incoming one, so the seam
    // between them blends into picture rather than into transparency.
    let movedA = a.clampedToExtent().transformed(
      by: CGAffineTransform(translationX: outgoing.x, y: -outgoing.y))
    let movedB = b.transformed(by: CGAffineTransform(translationX: incoming.x, y: -incoming.y))
    return movedB.composited(over: movedA)
  }

  /// `image` averaged along one axis over a box `length` pixels long: the
  /// picture moved across that span, built from pairs of halves so any length
  /// takes a handful of passes and every pixel of the span is read.
  private static func motionBlurred(
    _ image: CIImage, horizontal: Bool, length: Double, frame: CGRect
  ) -> CIImage {
    guard length >= 2 else { return image.cropped(to: frame) }
    let stages = Int(ceil(log2(length)))
    let step = length / pow(2, Double(stages))
    var result = image.clampedToExtent()
    var offset = step
    for _ in 0..<stages {
      let moved = result.transformed(
        by: horizontal
          ? CGAffineTransform(translationX: CGFloat(offset), y: 0)
          : CGAffineTransform(translationX: 0, y: CGFloat(offset)))
      result = withOpacity(moved, 0.5).applyingFilter(
        "CIAdditionCompositing",
        parameters: [kCIInputBackgroundImageKey: withOpacity(result, 0.5)])
      offset *= 2
    }
    // The taps start at the pixel itself; center them on it.
    let back = -CGFloat(length - step) / 2
    return result.transformed(
      by: horizontal
        ? CGAffineTransform(translationX: back, y: 0)
        : CGAffineTransform(translationX: 0, y: back)
    ).cropped(to: frame)
  }

  /// `image` lerped toward white by `strength`.
  private static func brightened(_ image: CIImage, by strength: Double) -> CIImage {
    guard strength > 0 else { return image }
    let keep = CGFloat(1 - strength)
    let add = CGFloat(strength)
    return image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: keep, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: keep, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: keep, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: add, y: add, z: add, w: 0),
      ])
  }

  /// The incoming clip inside a circle about the center, growing with `p`
  /// until, at 1, its soft edge has passed the corners.
  private static func irised(_ a: CIImage, _ b: CIImage, size: CGSize, p: Double) -> CIImage {
    let cx = Double(size.width) / 2
    let cy = Double(size.height) / 2
    let radius = max(p, 0) * (hypot(cx, cy) + irisEdge)
    guard radius > 0 else { return a }
    let mask = CIFilter(
      name: "CIRadialGradient",
      parameters: [
        "inputCenter": CIVector(x: CGFloat(cx), y: CGFloat(cy)),
        "inputRadius0": max(radius - irisEdge, 0),
        "inputRadius1": radius,
        "inputColor0": CIColor(red: 1, green: 1, blue: 1),
        "inputColor1": CIColor(red: 0, green: 0, blue: 0),
      ])?.outputImage
    guard let mask else { return p >= 0.5 ? b : a }
    return b.applyingFilter(
      "CIBlendWithMask",
      parameters: [kCIInputBackgroundImageKey: a, kCIInputMaskImageKey: mask])
  }

  /// The incoming clip squeezed into a share `p` of the frame at the edge it
  /// enters from, the outgoing clip into the rest.
  private static func stretched(
    _ a: CIImage, _ b: CIImage, size: CGSize, p: Double, direction: String
  ) -> CIImage {
    let w = size.width
    let h = size.height
    let incomingShare = CGFloat(p)
    let outgoingShare = CGFloat(1 - p)
    // Where each clip sits, in Core Image's y-up space: moving left or up the
    // incoming clip enters at the right edge or at the bottom.
    let incomingOrigin: CGPoint
    let outgoingOrigin: CGPoint
    let horizontal = direction != "up" && direction != "down"
    switch direction {
    case "right":
      incomingOrigin = .zero
      outgoingOrigin = CGPoint(x: w * incomingShare, y: 0)
    case "up":
      incomingOrigin = .zero
      outgoingOrigin = CGPoint(x: 0, y: h * incomingShare)
    case "down":
      incomingOrigin = CGPoint(x: 0, y: h * outgoingShare)
      outgoingOrigin = .zero
    default:
      incomingOrigin = CGPoint(x: w * outgoingShare, y: 0)
      outgoingOrigin = .zero
    }
    func squeezed(_ image: CIImage, share: CGFloat, origin: CGPoint) -> CIImage? {
      guard share > 1e-6 else { return nil }
      let scale =
        horizontal
        ? CGAffineTransform(scaleX: share, y: 1) : CGAffineTransform(scaleX: 1, y: share)
      let region = CGRect(
        x: origin.x, y: origin.y,
        width: horizontal ? w * share : w, height: horizontal ? h : h * share)
      return image.clampedToExtent().transformed(
        by: scale.concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
      ).cropped(to: region)
    }
    let outgoing = squeezed(a, share: outgoingShare, origin: outgoingOrigin)
    let incoming = squeezed(b, share: incomingShare, origin: incomingOrigin)
    switch (outgoing, incoming) {
    case let (outgoing?, incoming?): return incoming.composited(over: outgoing)
    case let (outgoing?, nil): return outgoing
    case let (nil, incoming?): return incoming
    default: return a
    }
  }

  // MARK: - Glitch

  /// The glitch: slices of the picture moved right by their shift (edges
  /// repeated) and showing their own clip, then red read the split to the
  /// right and blue as far to the left.
  private static func glitched(
    _ a: CIImage, _ b: CIImage, size: CGSize, c: Double, phase: Int
  ) -> CIImage {
    let width = Int(size.width.rounded())
    let height = Int(size.height.rounded())
    let bands = glitchBands(c: c, phase: phase, width: width)
    var banded = CIImage.empty()
    for (index, band) in bands.enumerated() {
      // Android puts row y in slice y * count / height; this is its first
      // and last row, counted from the top.
      let top = (index * height + glitchBandCount - 1) / glitchBandCount
      let bottom = ((index + 1) * height + glitchBandCount - 1) / glitchBandCount
      guard bottom > top else { continue }
      let rows = CGRect(
        x: 0, y: CGFloat(height - bottom), width: size.width, height: CGFloat(bottom - top))
      let source = band.showsIncoming ? b : a
      banded = source.samplingNearest().clampedToExtent()
        .transformed(by: CGAffineTransform(translationX: CGFloat(band.shift), y: 0))
        .cropped(to: rows)
        .composited(over: banded)
    }
    let frame = CGRect(origin: .zero, size: size)
    banded = banded.cropped(to: frame)
    let split = glitchSplitPixels(c: c, width: width)
    guard split != 0 else { return banded }
    let clamped = banded.samplingNearest().clampedToExtent()
    let d = CGFloat(split)
    let red = isolatingChannel(
      clamped.transformed(by: CGAffineTransform(translationX: -d, y: 0)), 0
    ).cropped(to: frame)
    let green = isolatingChannel(banded, 1)
    let blue = isolatingChannel(
      clamped.transformed(by: CGAffineTransform(translationX: d, y: 0)), 2
    ).cropped(to: frame)
    return
      red
      .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: green])
      .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: blue])
  }

  /// Keeps one color channel with opaque alpha, as the RGB split effect does.
  private static func isolatingChannel(_ image: CIImage, _ channel: Int) -> CIImage {
    let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
    return image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": channel == 0 ? CIVector(x: 1, y: 0, z: 0, w: 0) : zero,
        "inputGVector": channel == 1 ? CIVector(x: 0, y: 1, z: 0, w: 0) : zero,
        "inputBVector": channel == 2 ? CIVector(x: 0, y: 0, z: 1, w: 0) : zero,
        "inputAVector": zero,
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      ])
  }
}
