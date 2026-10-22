import CoreImage
import Foundation

/// How a layer's pixels combine with the picture beneath it; Dart's
/// `LayerBlendMode`, matched by name.
///
/// Every mode is the separable blend of the W3C compositing spec (and of
/// Flutter's `BlendMode` of the same name): the blend of each color channel,
/// faded in by the layer's alpha. Core Image's stock blend filters compute
/// exactly that on premultiplied values; with `workingColorSpace: NSNull()`
/// they do so on the values as stored, as Flutter does on screen.
enum LayerBlendMode: String, CaseIterable, Sendable {
  case normal
  case multiply
  case screen
  case overlay
  case softLight
  case darken
  case lighten
  case add
  case difference

  /// The mode named [raw], or `.normal` for anything else.
  static func from(_ raw: Any?) -> LayerBlendMode {
    (raw as? String).flatMap(LayerBlendMode.init(rawValue:)) ?? .normal
  }

  /// The Core Image filter that blends a source over its
  /// `inputBackgroundImage` as this mode does; `nil` for `.normal` and `.add`,
  /// which `blendLayer` draws otherwise.
  fileprivate var filterName: String? {
    switch self {
    case .normal, .add: return nil
    case .multiply: return "CIMultiplyBlendMode"
    case .screen: return "CIScreenBlendMode"
    case .overlay: return "CIOverlayBlendMode"
    case .softLight: return "CISoftLightBlendMode"
    case .darken: return "CIDarkenBlendMode"
    case .lighten: return "CILightenBlendMode"
    case .difference: return "CIDifferenceBlendMode"
    }
  }
}

/// [layer], already placed and faded, drawn onto [backdrop] with [mode].
///
/// Where [layer] is transparent [backdrop] stays as it is. `.add` is
/// `CIAdditionCompositing` clamped to white per premultiplied channel, the
/// alpha included: the plus of Flutter's `BlendMode.plus`. `CIColorClamp`
/// would clamp the unpremultiplied colors instead and halve them where the
/// summed alpha passes 1, and `CILinearDodgeBlendMode` fades the sum in by the
/// layer's alpha rather than adding the premultiplied colors.
func blendLayer(_ layer: CIImage, over backdrop: CIImage, mode: LayerBlendMode) -> CIImage {
  switch mode {
  case .normal:
    return layer.composited(over: backdrop)
  case .add:
    return layer.applyingFilter(
      "CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: backdrop]
    )
    .applyingFilter(
      "CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: CIImage(color: .white)]
    )
    .cropped(to: backdrop.extent)
  default:
    return layer.applyingFilter(
      mode.filterName!, parameters: [kCIInputBackgroundImageKey: backdrop])
  }
}
