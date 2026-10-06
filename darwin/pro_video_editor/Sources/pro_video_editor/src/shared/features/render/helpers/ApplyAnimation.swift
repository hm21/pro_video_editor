import CoreImage
import Foundation

/// Applies an easing function to a linear progress value (0...1).
func applyEasing(_ t: Double, curve: String) -> Double {
  switch curve {
  case "easeIn":
    return t * t
  case "easeOut":
    return t * (2 - t)
  case "easeInOut":
    return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t
  case "easeInCubic":
    return t * t * t
  case "easeOutCubic":
    let p = 1 - t
    return 1 - p * p * p
  case "easeInOutCubic":
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
  case "bounceIn":
    return 1 - applyEasing(1 - t, curve: "bounceOut")
  case "bounceOut":
    if t < 1 / 2.75 {
      return 7.5625 * t * t
    } else if t < 2 / 2.75 {
      let t2 = t - 1.5 / 2.75
      return 7.5625 * t2 * t2 + 0.75
    } else if t < 2.5 / 2.75 {
      let t2 = t - 2.25 / 2.75
      return 7.5625 * t2 * t2 + 0.9375
    } else {
      let t2 = t - 2.625 / 2.75
      return 7.5625 * t2 * t2 + 0.984375
    }
  case "bounceInOut":
    if t < 0.5 {
      return (1 - applyEasing(1 - 2 * t, curve: "bounceOut")) / 2
    } else {
      return (1 + applyEasing(2 * t - 1, curve: "bounceOut")) / 2
    }
  case "elasticIn":
    return 1 - applyEasing(1 - t, curve: "elasticOut")
  case "elasticOut":
    if t == 0 || t == 1 { return t }
    return pow(2, -10 * t) * sin((t - 0.075) * (2 * .pi) / 0.3) + 1
  case "elasticInOut":
    if t < 0.5 {
      return (1 - applyEasing(1 - 2 * t, curve: "elasticOut")) / 2
    } else {
      return (1 + applyEasing(2 * t - 1, curve: "elasticOut")) / 2
    }
  default:  // "linear"
    return t
  }
}

/// Computes the slide translation (frame pixel space, Core Graphics Y bottom-up)
/// that moves an overlay fully out of the frame in `direction`, edge-aware
/// rather than overlay-size-relative.
///
/// At `invP == 1` the overlay's trailing edge sits exactly on the frame edge in
/// the slide direction (so the overlay is just completely outside); at
/// `invP == 0` the offset is `.zero` (overlay at rest). Visually identical to
/// the Android `slideOffset` in normalized coordinates.
func slideOffset(
  direction: String,
  invP: CGFloat,
  overlayExtent: CGRect,
  frameExtent: CGRect
) -> CGPoint {
  switch direction {
  case "left":  // right edge → frame left
    return CGPoint(x: (frameExtent.minX - overlayExtent.maxX) * invP, y: 0)
  case "right":  // left edge → frame right
    return CGPoint(x: (frameExtent.maxX - overlayExtent.minX) * invP, y: 0)
  case "top":  // bottom edge → frame top (Core Graphics top edge is maxY)
    return CGPoint(x: 0, y: (frameExtent.maxY - overlayExtent.minY) * invP)
  case "bottom":  // top edge → frame bottom (Core Graphics bottom edge is minY)
    return CGPoint(x: 0, y: (frameExtent.minY - overlayExtent.maxY) * invP)
  default:
    return .zero
  }
}

/// Computes the slide translation toward a caller-chosen start point instead of
/// a frame edge (see `slideOffset`).
///
/// `slideFrom` and `layerOrigin` are both the layer's top-left corner in frame
/// pixels with Flutter's top-left origin, so their difference is the distance
/// the overlay travels — its own size cancels out. The result is in Core
/// Graphics space (Y bottom-up), which flips the vertical component.
///
/// At `invP == 1` the overlay sits on the start point; at `invP == 0` it rests.
func slideFromOffset(
  invP: CGFloat,
  slideFrom: CGPoint,
  layerOrigin: CGPoint
) -> CGPoint {
  CGPoint(
    x: (slideFrom.x - layerOrigin.x) * invP,
    y: -(slideFrom.y - layerOrigin.y) * invP
  )
}

/// How far an animation has brought a layer back to rest at one moment:
/// `value` is 1 at rest and 0 fully away (faded out, at the edge, tilted all
/// the way), and may overshoot either end with an elastic or bounce curve.
///
/// `swing` is the side a wiggle tilts to: -1 in the second half of a loop
/// cycle, 1 otherwise.
struct AnimationProgress: Equatable {
  let value: Double
  var swing: Double = 1
}

/// The progress of [anim] at [currentTimeUs], or `nil` when it does not play
/// then.
///
/// [startUs] and [endUs] are the range the animation counts from and towards
/// (-1 = the start / the end of the video): an in-animation plays over the
/// first `durationUs` of it and an out-animation over the last. With
/// "animateInOut" both apply and the one further from rest wins.
///
/// A "loop" plays over the whole range, one cycle per duration counted from
/// [startUs]: the eased value runs from rest to fully away at half a cycle and
/// back. A wiggle runs that twice per cycle, once to each side. The cycle
/// position is taken from the remainder of whole microseconds, so a long video
/// does not lose precision. Mirrors `animationProgress` on Android.
func animationProgress(
  _ anim: LayerAnimationConfig,
  currentTimeUs: Int64,
  startUs: Int64,
  endUs: Int64
) -> AnimationProgress? {
  let durationUs = anim.durationUs
  guard durationUs > 0 else { return nil }

  let effectiveStartUs = startUs == -1 ? Int64(0) : startUs
  let effectiveEndUs = endUs == -1 ? Int64.max : endUs

  if anim.phase == "loop" {
    let elapsed = max(0, currentTimeUs - effectiveStartUs)
    let inCycle = elapsed % durationUs
    if anim.type == "wiggle" {
      // Each half of the cycle is one swing out and back.
      let inSwing = (2 * inCycle) % durationUs
      let x = abs(1 - 2 * Double(inSwing) / Double(durationUs))
      return AnimationProgress(
        value: applyEasing(x, curve: anim.curve),
        swing: 2 * inCycle < durationUs ? 1 : -1)
    }
    let x = abs(1 - 2 * Double(inCycle) / Double(durationUs))
    return AnimationProgress(value: applyEasing(x, curve: anim.curve))
  }

  var inProgress: Double? = nil
  var outProgress: Double? = nil

  if anim.phase == "animateIn" || anim.phase == "animateInOut" {
    let elapsed = currentTimeUs - effectiveStartUs
    if elapsed < durationUs {
      inProgress = applyEasing(
        max(0, min(1, Double(elapsed) / Double(durationUs))),
        curve: anim.curve
      )
    }
  }

  if anim.phase == "animateOut" || anim.phase == "animateInOut" {
    let remaining = effectiveEndUs - currentTimeUs
    if remaining < durationUs {
      outProgress = applyEasing(
        max(0, min(1, Double(remaining) / Double(durationUs))),
        curve: anim.curve
      )
    }
  }

  // Use the minimum progress (most visible animation effect)
  if let inp = inProgress, let outp = outProgress {
    return AnimationProgress(value: min(inp, outp))
  }
  guard let progress = inProgress ?? outProgress else { return nil }
  return AnimationProgress(value: progress)
}

/// Computes animation transforms and opacity for overlaying an image layer.
/// Returns (opacity, additionalTransform) to apply to the overlay.
///
/// The animations count from the layer's `animationStartUs` / `animationEndUs`
/// where set, else from its own time range. Opacity and scale multiply, slide
/// offsets add up. A wiggle tilts the overlay around its own center before
/// anything else moves it, and a bounce lifts it by a multiple of its own
/// height after it is scaled, the order the editor preview composes them in.
/// Text reveals ("typewriter", "wordByWord") change what the image shows,
/// which a fixed image cannot do, so they are skipped; the caller passes one
/// layer per step instead.
func computeAnimation(
  layer: ImageLayer,
  currentTimeUs: Int64,
  overlayExtent: CGRect,
  frameExtent: CGRect
) -> (opacity: Double, transform: CGAffineTransform) {
  var opacity = 1.0
  var animTransform = CGAffineTransform.identity
  // Clockwise, in radians, like Flutter's rotation.
  var wiggle = 0.0
  // Upwards, in Core Graphics pixels.
  var lift: CGFloat = 0

  let startUs = layer.animationStartUs == -1 ? layer.startUs : layer.animationStartUs
  let endUs = layer.animationEndUs == -1 ? layer.endUs : layer.animationEndUs

  for anim in layer.animations {
    guard
      let progress = animationProgress(
        anim, currentTimeUs: currentTimeUs, startUs: startUs, endUs: endUs)
    else { continue }
    let p = progress.value

    switch anim.type {
    case "fade":
      opacity *= p

    case "slide":
      let invP = CGFloat(1.0 - p)
      let off: CGPoint
      // A caller-chosen start point wins over the edge the direction picks.
      if let slideFrom = anim.slideFrom {
        // A stretched layer (no x/y) rests on the frame origin.
        let layerOrigin = CGPoint(x: CGFloat(layer.x ?? 0), y: CGFloat(layer.y ?? 0))
        off = slideFromOffset(invP: invP, slideFrom: slideFrom, layerOrigin: layerOrigin)
      } else if let direction = anim.slideDirection {
        off = slideOffset(
          direction: direction,
          invP: invP,
          overlayExtent: overlayExtent,
          frameExtent: frameExtent
        )
      } else {
        // Neither a start point nor a direction: nothing to travel along, so
        // the layer stays put. Matches the Android `slideOffset` fallback —
        // defaulting to the left edge here would slide a layer the caller
        // never asked to move.
        off = .zero
      }
      animTransform = animTransform.translatedBy(x: off.x, y: off.y)

    case "scale":
      let scaleFrom = CGFloat(anim.scaleFrom ?? 0.0)
      let currentScale = scaleFrom + (1.0 - scaleFrom) * CGFloat(p)
      let cx = overlayExtent.midX
      let cy = overlayExtent.midY
      animTransform =
        animTransform
        .translatedBy(x: cx, y: cy)
        .scaledBy(x: currentScale, y: currentScale)
        .translatedBy(x: -cx, y: -cy)

    case "wiggle":
      let angle = anim.wiggleAngle ?? LayerAnimationConfig.defaultWiggleAngle
      wiggle += progress.swing * (1 - p) * angle

    case "bounce":
      let height = anim.bounceHeight ?? LayerAnimationConfig.defaultBounceHeight
      lift += CGFloat((1 - p) * height) * overlayExtent.height

    default:
      break
    }
  }

  // Clamp values — elastic/bounce curves can overshoot [0,1]
  opacity = max(0, min(1, opacity))

  var transform = animTransform
  if wiggle != 0 {
    // Core Graphics turns counter-clockwise, so the angle is negated.
    let cx = overlayExtent.midX
    let cy = overlayExtent.midY
    let tilt = CGAffineTransform(translationX: cx, y: cy)
      .rotated(by: CGFloat(-wiggle))
      .translatedBy(x: -cx, y: -cy)
    transform = tilt.concatenating(transform)
  }
  if lift != 0 {
    transform = transform.concatenating(CGAffineTransform(translationX: 0, y: lift))
  }

  return (opacity, transform)
}

/// Composites an overlay image onto the output with animation effects applied.
func compositeOverlay(
  _ overlay: CIImage,
  over outputImage: CIImage,
  opacity: Double,
  transform: CGAffineTransform
) -> CIImage {
  placedOverlay(overlay, opacity: opacity, transform: transform).composited(over: outputImage)
}

/// [overlay] with its animation applied: moved and scaled by [transform] and
/// faded to [opacity].
func placedOverlay(
  _ overlay: CIImage,
  opacity: Double,
  transform: CGAffineTransform
) -> CIImage {
  var result = overlay

  // Apply animation transform (slide, scale)
  if !transform.isIdentity {
    result = result.transformed(by: transform)
  }

  // Apply opacity (fade)
  if opacity < 1.0 {
    result = result.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
      ])
  }

  return result
}
