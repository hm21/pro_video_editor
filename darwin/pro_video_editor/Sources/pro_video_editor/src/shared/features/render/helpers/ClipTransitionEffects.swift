import CoreImage
import Foundation

/// Core Image drawing for the overlap transitions that move, blur or flash the
/// picture — zoom in and out, spin, whip pan, blur, glitch, flash, iris,
/// stretch, light leak, clock and diagonal wipes, flip and cube.
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
  /// Progress window in which lightLeak changes clip, hidden under its light.
  static let leakSwapStart = 0.35
  static let leakSwapEnd = 0.65
  /// How bright lightLeak's lights are at mid-transition, as a multiple of
  /// their colors.
  static let leakGain = 2.2
  /// Width of the soft edge of clockWipe and diagonalWipe, in frame pixels.
  static let wipeEdge = 2.0
  /// How far the camera is from flip and cube, as a multiple of the side
  /// that turns.
  static let turnDistance = 2.0
  /// How much flip and cube darken a face turned edge-on.
  static let turnShade = 0.4

  /// One of lightLeak's warm lights: its color, where its centre starts and
  /// ends as fractions of the frame from the top left, and its reach as
  /// fractions of the frame's longer side. The colors are the light leak
  /// video effect's.
  struct LeakLight {
    let red: Double
    let green: Double
    let blue: Double
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double
    let reachX: Double
    let reachY: Double
  }

  /// lightLeak's lights, drifting from the left edge across the frame.
  static let leakLights = [
    LeakLight(
      red: 0.95, green: 0.49, blue: 0.17, startX: -0.2, startY: 0.3, endX: 0.85, endY: 0.5,
      reachX: 0.55, reachY: 0.8),
    LeakLight(
      red: 0.75, green: 0.21, blue: 0.24, startX: -0.1, startY: -0.05, endX: 1.1, endY: 0.1,
      reachX: 0.6, reachY: 0.3),
    LeakLight(
      red: 0.55, green: 0.45, blue: 0.28, startX: -0.3, startY: 0.85, endX: 0.7, endY: 0.7,
      reachX: 0.4, reachY: 0.4),
  ]

  /// Offsets ``glitchHash`` so slice 0 of pattern 0 does not hash to 0.
  private static let glitchSeed: UInt32 = 0x9E37_79B9

  private static let types: Set<String> = [
    "zoomIn", "zoomOut", "spin", "whipPan", "blur", "glitch", "flash", "iris", "stretch",
    "lightLeak", "clockWipe", "diagonalWipe", "flip", "cube",
  ]

  /// Whether ``compose`` draws `type` for every blend.
  ///
  /// It draws `dissolve`, `slide`, `push` and `wipe` too, as the layer
  /// instructions `ClipTransitionRenderer` uses for them do, for a blend whose
  /// sides move by their keyframes and so need to be drawn frame by frame.
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
    case "lightLeak":
      result = lightLeaked(
        layered(bottom: a, top: b, topOpacity: smoothstep(leakSwapStart, leakSwapEnd, c)),
        size: size, c: c)
    case "clockWipe":
      result = clockWiped(a, b, size: size, c: c)
    case "diagonalWipe":
      result = diagonalWiped(a, b, size: size, c: c, direction: direction)
    case "flip", "cube":
      result = turned(
        a, b, size: size, faces: turnedFaces(type: type, direction: direction, size: size, p: p))
    case "dissolve":
      // The outgoing frame on top, fading out to reveal the incoming one.
      result = layered(bottom: b, top: a, topOpacity: 1 - c)
    case "slide":
      result = slid(b, over: a, size: size, p: p, direction: direction)
    case "push":
      result = pushed(a, b, size: size, p: p, direction: direction)
    case "wipe":
      result = wiped(b, over: a, size: size, p: c, direction: direction)
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

  /// How strong lightLeak's lights are at clamped progress `c`: 0 at either
  /// end, 1 at the midpoint.
  static func leakStrength(_ c: Double) -> Double {
    let s = sin(Double.pi * c)
    return s * s
  }

  /// The corner diagonalWipe's edge travels toward, an eighth of a turn
  /// clockwise from `direction`: left → top left, up → top right, right →
  /// bottom right, down → bottom left. Its `x` and `y` are 0 for the left or
  /// top edge and 1 for the right or bottom one.
  static func diagonalCorner(_ direction: String) -> (x: Double, y: Double) {
    switch direction {
    case "right": (1, 1)
    case "up": (1, 0)
    case "down": (0, 1)
    default: (0, 0)
    }
  }

  /// One face of flip or cube on screen.
  struct TurnedFace: Equatable {
    /// Whether the face shows the outgoing clip.
    let outgoing: Bool
    /// Its corners in top-origin frame pixels: top left, top right, bottom
    /// right and bottom left of its picture.
    let corners: [CGPoint]
    /// How much of its picture's brightness it keeps.
    let shade: Double
  }

  /// The faces flip or cube shows at progress `p` in a frame of `size`,
  /// farthest first; a face turned away or edge-on is left out.
  ///
  /// Flip turns a card about the frame's middle: the outgoing clip on its
  /// front until it stands edge-on halfway through, the incoming clip on its
  /// back after. Cube turns the outgoing clip away as one side of a cube and
  /// brings the incoming clip in as the next side. Both turn about a vertical
  /// axis for left and right and a horizontal one for up and down, the edge
  /// opposite the direction swinging toward the viewer. They move back just far
  /// enough that no edge comes closer than the frame, are seen from
  /// ``turnDistance`` times the turning side away, and darken by up to
  /// ``turnShade`` as they turn.
  static func turnedFaces(type: String, direction: String, size: CGSize, p: Double)
    -> [TurnedFace]
  {
    let width = Double(size.width)
    let height = Double(size.height)
    let horizontal = direction != "up" && direction != "down"
    // Left and up turn the far end (right or bottom edge) toward the viewer.
    let sign = direction == "right" || direction == "down" ? -1.0 : 1.0
    let side = horizontal ? width : height
    let across = horizontal ? height : width
    let cube = type == "cube"
    // The faces turn about an axis this far behind the frame.
    let pivot = cube ? side / 2 : 0
    let angles: [(outgoing: Bool, angle: Double)] =
      cube
      ? [(true, Double.pi / 2 * p), (false, Double.pi / 2 * (p - 1))]
      : (p < 0.5 ? [(true, Double.pi * p)] : [(false, Double.pi * (p - 1))])
    // Each corner along the turning side and across it, as offsets from the
    // middle: top left, top right, bottom right, bottom left.
    let offsets: [(along: Double, across: Double)] =
      horizontal
      ? [(-side / 2, -across / 2), (side / 2, -across / 2), (side / 2, across / 2),
        (-side / 2, across / 2)]
      : [(-side / 2, -across / 2), (-side / 2, across / 2), (side / 2, across / 2),
        (side / 2, -across / 2)]
    let turned = angles.map { face in
      offsets.map { offset -> (along: Double, across: Double, depth: Double) in
        let cosine = cos(face.angle)
        let sine = sin(face.angle)
        return (
          offset.along * cosine - sign * pivot * sine, offset.across,
          sign * offset.along * sine + pivot * cosine - pivot
        )
      }
    }
    let nearest = max(turned.flatMap { $0.map(\.depth) }.max() ?? 0, 0)
    let distance = turnDistance * side
    var faces: [(face: TurnedFace, depth: Double)] = []
    for (face, corners) in zip(angles, turned) {
      let points = corners.map { corner -> CGPoint in
        let scale = distance / (distance - (corner.depth - nearest))
        let along = side / 2 + corner.along * scale
        let crossed = across / 2 + corner.across * scale
        return horizontal ? CGPoint(x: along, y: crossed) : CGPoint(x: crossed, y: along)
      }
      guard shoelaceArea(points) > 1 else { continue }
      let depth = corners.map(\.depth).reduce(0, +) / Double(corners.count)
      faces.append(
        (
          TurnedFace(
            outgoing: face.outgoing, corners: points,
            shade: 1 - turnShade * abs(sin(face.angle))),
          depth
        ))
    }
    // Equally far, the outgoing face goes first, as on Android.
    return faces.sorted {
      $0.depth != $1.depth ? $0.depth < $1.depth : $0.face.outgoing && !$1.face.outgoing
    }.map(\.face)
  }

  /// The area of the quad `points`, positive when they run clockwise on
  /// screen as a face seen from the front does.
  private static func shoelaceArea(_ points: [CGPoint]) -> Double {
    var sum = 0.0
    for (index, point) in points.enumerated() {
      let next = points[(index + 1) % points.count]
      sum += Double(point.x * next.y - next.x * point.y)
    }
    return sum / 2
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

  /// `incoming` sliding in over the still `outgoing` frame from the side
  /// opposite `direction`, `p` of the way.
  private static func slid(
    _ incoming: CIImage, over outgoing: CIImage, size: CGSize, p: Double, direction: String
  ) -> CIImage {
    let rest = CGFloat(1 - p)
    // Moves in top-origin terms; Core Image's y axis points up.
    let move: CGPoint =
      switch direction {
      case "right": CGPoint(x: -size.width * rest, y: 0)
      case "up": CGPoint(x: 0, y: size.height * rest)
      case "down": CGPoint(x: 0, y: -size.height * rest)
      default: CGPoint(x: size.width * rest, y: 0)
      }
    return incoming.transformed(by: CGAffineTransform(translationX: move.x, y: -move.y))
      .composited(over: outgoing)
  }

  /// `incoming` revealed over `outgoing` by an edge moving toward
  /// `direction`, `p` of the way across.
  private static func wiped(
    _ incoming: CIImage, over outgoing: CIImage, size: CGSize, p: Double, direction: String
  ) -> CIImage {
    let w = size.width
    let h = size.height
    let shown = CGFloat(p)
    // Core Image's y axis points up: a wipe down reveals the top band.
    let rect: CGRect =
      switch direction {
      case "left": CGRect(x: w * (1 - shown), y: 0, width: w * shown, height: h)
      case "down": CGRect(x: 0, y: h * (1 - shown), width: w, height: h * shown)
      case "up": CGRect(x: 0, y: 0, width: w, height: h * shown)
      default: CGRect(x: 0, y: 0, width: w * shown, height: h)
      }
    return incoming.cropped(to: rect).composited(over: outgoing)
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

  /// `picture` brightened by lightLeak's lights at clamped progress `c`, each
  /// screened over it in turn.
  private static func lightLeaked(_ picture: CIImage, size: CGSize, c: Double) -> CIImage {
    let strength = leakGain * leakStrength(c)
    // sin(π) is not quite 0; a light this faint changes nothing.
    guard strength >= 1e-6 else { return picture }
    let width = Double(size.width)
    let height = Double(size.height)
    let longer = max(width, height)
    var result = picture
    for light in leakLights {
      let x = (light.startX + (light.endX - light.startX) * c) * width
      // Core Image's y axis points up.
      let y = height - (light.startY + (light.endY - light.startY) * c) * height
      let reachX = light.reachX * longer
      let reachY = light.reachY * longer
      // CIGaussianGradient falls off as smoothstep(1 - r / radius). Placing
      // it by its own centre and radius rather than by a transform keeps
      // every light a distinct generator: Core Image draws two equal
      // generators moved apart as one.
      guard
        let gradient = CIFilter(
          name: "CIGaussianGradient",
          parameters: [
            "inputCenter": CIVector(x: CGFloat(x), y: CGFloat(y)),
            "inputRadius": reachX,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0),
          ])?.outputImage
      else { continue }
      let glow = gradient.transformed(
        by: CGAffineTransform(translationX: 0, y: CGFloat(-y))
          .concatenating(CGAffineTransform(scaleX: 1, y: CGFloat(reachY / reachX)))
          .concatenating(CGAffineTransform(translationX: 0, y: CGFloat(y)))
      )
      .applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: CGFloat(light.red * strength), y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: CGFloat(light.green * strength), z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(light.blue * strength), w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]
      )
      .applyingFilter(
        "CIColorClamp",
        parameters: [
          "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
      result = glow.applyingFilter(
        "CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: result])
    }
    return result
  }

  /// A mask that is 0 behind the line through `point` (top-origin pixels)
  /// across `normal` and 1 ahead of it, ramping over ``wipeEdge`` centred on
  /// the line.
  private static func halfPlane(through point: CGPoint, normal: CGPoint, height: CGFloat)
    -> CIImage
  {
    let half = CGFloat(wipeEdge / 2)
    // Core Image's y axis points up.
    let from = CIVector(x: point.x - normal.x * half, y: height - (point.y - normal.y * half))
    let to = CIVector(x: point.x + normal.x * half, y: height - (point.y + normal.y * half))
    return CIFilter(
      name: "CILinearGradient",
      parameters: [
        "inputPoint0": from, "inputPoint1": to,
        "inputColor0": CIColor(red: 0, green: 0, blue: 0),
        "inputColor1": CIColor(red: 1, green: 1, blue: 1),
      ])?.outputImage ?? CIImage(color: .black)
  }

  /// The incoming clip revealed behind a hand sweeping clockwise from twelve
  /// o'clock, a full turn at clamped progress 1.
  ///
  /// The swept part is the right half and the half-plane behind the hand,
  /// both soft-edged: both at once up to half a turn, either beyond it.
  /// Beyond half a turn their sum, kept to 1, leaves no seam where their
  /// edges run side by side below the centre.
  private static func clockWiped(_ a: CIImage, _ b: CIImage, size: CGSize, c: Double) -> CIImage {
    guard c > 0 else { return a }
    guard c < 1 else { return b }
    let angle = 2 * Double.pi * c
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let right = halfPlane(through: center, normal: CGPoint(x: 1, y: 0), height: size.height)
    let hand = halfPlane(
      through: center, normal: CGPoint(x: -cos(angle), y: -sin(angle)), height: size.height)
    let mask = hand.applyingFilter(
      angle <= Double.pi ? "CIMinimumCompositing" : "CILinearDodgeBlendMode",
      parameters: [kCIInputBackgroundImageKey: right])
    return b.applyingFilter(
      "CIBlendWithMask",
      parameters: [kCIInputBackgroundImageKey: a, kCIInputMaskImageKey: mask])
  }

  /// The incoming clip revealed by an edge, parallel to the frame's other
  /// diagonal, travelling from the corner opposite ``diagonalCorner`` to it.
  ///
  /// Like iris, the soft edge runs behind the edge, so nothing shows at 0
  /// and the far corner is covered at 1.
  private static func diagonalWiped(
    _ a: CIImage, _ b: CIImage, size: CGSize, c: Double, direction: String
  ) -> CIImage {
    guard c > 0 else { return a }
    guard c < 1 else { return b }
    let width = Double(size.width)
    let height = Double(size.height)
    let target = diagonalCorner(direction)
    let start = CGPoint(x: (1 - target.x) * width, y: (1 - target.y) * height)
    // Toward the target, across the lines x / width + y / height = constant.
    let toward = (x: (2 * target.x - 1) / width, y: (2 * target.y - 1) / height)
    let length = hypot(toward.x, toward.y)
    let normal = CGPoint(x: toward.x / length, y: toward.y / length)
    let travel = 2 / length
    let edge = c * (travel + wipeEdge)
    func along(_ distance: Double) -> CIVector {
      // Core Image's y axis points up.
      CIVector(
        x: start.x + normal.x * CGFloat(distance),
        y: size.height - (start.y + normal.y * CGFloat(distance)))
    }
    guard
      let mask = CIFilter(
        name: "CILinearGradient",
        parameters: [
          "inputPoint0": along(edge - wipeEdge), "inputPoint1": along(edge),
          "inputColor0": CIColor(red: 1, green: 1, blue: 1),
          "inputColor1": CIColor(red: 0, green: 0, blue: 0),
        ])?.outputImage
    else { return c >= 0.5 ? b : a }
    return b.applyingFilter(
      "CIBlendWithMask",
      parameters: [kCIInputBackgroundImageKey: a, kCIInputMaskImageKey: mask])
  }

  /// `faces` drawn over black, each picture darkened by its shade and moved
  /// onto its corners.
  private static func turned(_ a: CIImage, _ b: CIImage, size: CGSize, faces: [TurnedFace])
    -> CIImage
  {
    var result = CIImage(color: .black)
    for face in faces {
      let source = face.outgoing ? a : b
      let shade = CGFloat(face.shade)
      // Core Image's y axis points up.
      func corner(_ index: Int) -> CIVector {
        CIVector(x: face.corners[index].x, y: size.height - face.corners[index].y)
      }
      let moved = source.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: shade, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: shade, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: shade, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]
      ).applyingFilter(
        "CIPerspectiveTransform",
        parameters: [
          "inputTopLeft": corner(0), "inputTopRight": corner(1),
          "inputBottomRight": corner(2), "inputBottomLeft": corner(3),
        ])
      result = moved.composited(over: result)
    }
    return result
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
