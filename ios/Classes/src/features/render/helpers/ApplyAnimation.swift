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

/// Computes animation transforms and opacity for overlaying an image layer.
/// Returns (opacity, additionalTransform) to apply to the overlay.
func computeAnimation(
    layer: ImageLayer,
    currentTimeUs: Int64,
    overlayExtent: CGRect,
    frameExtent: CGRect
) -> (opacity: Double, transform: CGAffineTransform) {
    var opacity = 1.0
    var animTransform = CGAffineTransform.identity

    for anim in layer.animations {
        let durationUs = anim.durationUs
        guard durationUs > 0 else { continue }

        let layerStartUs = layer.startUs == -1 ? Int64(0) : layer.startUs
        let layerEndUs = layer.endUs == -1 ? Int64.max : layer.endUs

        // Determine raw progress for animateIn and/or animateOut
        var inProgress: Double? = nil
        var outProgress: Double? = nil

        if anim.phase == "animateIn" || anim.phase == "animateInOut" {
            let elapsed = currentTimeUs - layerStartUs
            if elapsed < durationUs {
                inProgress = applyEasing(
                    max(0, min(1, Double(elapsed) / Double(durationUs))),
                    curve: anim.curve
                )
            }
        }

        if anim.phase == "animateOut" || anim.phase == "animateInOut" {
            let remaining = layerEndUs - currentTimeUs
            if remaining < durationUs {
                outProgress = applyEasing(
                    max(0, min(1, Double(remaining) / Double(durationUs))),
                    curve: anim.curve
                )
            }
        }

        // Use the minimum progress (most visible animation effect)
        let progress: Double?
        if let inp = inProgress, let outp = outProgress {
            progress = min(inp, outp)
        } else {
            progress = inProgress ?? outProgress
        }

        guard let p = progress else { continue }

        switch anim.type {
        case "fade":
            opacity *= p

        case "slide":
            let direction = anim.slideDirection ?? "left"
            var dx: CGFloat = 0
            var dy: CGFloat = 0
            let invP = CGFloat(1.0 - p)

            switch direction {
            case "left":
                dx = -overlayExtent.width * invP
            case "right":
                dx = overlayExtent.width * invP
            case "top":
                // Core Graphics Y is bottom-up, so "top" means positive Y
                dy = overlayExtent.height * invP
            case "bottom":
                dy = -overlayExtent.height * invP
            default:
                break
            }
            animTransform = animTransform.translatedBy(x: dx, y: dy)

        case "scale":
            let scaleFrom = CGFloat(anim.scaleFrom ?? 0.0)
            let currentScale = scaleFrom + (1.0 - scaleFrom) * CGFloat(p)
            let cx = overlayExtent.midX
            let cy = overlayExtent.midY
            animTransform = animTransform
                .translatedBy(x: cx, y: cy)
                .scaledBy(x: currentScale, y: currentScale)
                .translatedBy(x: -cx, y: -cy)

        default:
            break
        }
    }

    return (opacity, animTransform)
}

/// Composites an overlay image onto the output with animation effects applied.
func compositeOverlay(
    _ overlay: CIImage,
    over outputImage: CIImage,
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
        result = result.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
        ])
    }

    return result.composited(over: outputImage)
}
