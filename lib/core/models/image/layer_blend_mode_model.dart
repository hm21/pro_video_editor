import 'dart:ui' show BlendMode;

/// How a layer's pixels combine with the picture beneath it.
///
/// Every mode but [normal] works on each color channel of a pixel apart, with
/// the layer's color as the *source* and the picture beneath it as the
/// *backdrop*, both from 0 (dark) to 1 (light). The layer's alpha — its own
/// transparency times its opacity, a fade animation or a keyframe's opacity —
/// then fades between the backdrop and the blended color, so a half
/// transparent pixel shows the backdrop halfway to the blended color, and
/// where the layer is transparent the backdrop stays as it is.
///
/// The colors are blended as they are stored in the video, without converting
/// them to linear light, as Flutter blends them on screen. Each mode is the
/// Flutter [BlendMode] of [blendMode], so a preview that paints the layer with
/// that mode over the same picture shows what the render produces.
enum LayerBlendMode {
  /// Draws the layer over the picture beneath it.
  normal,

  /// Multiplies the colors: the result is never lighter than either of them.
  /// White leaves the picture as it is and black turns it black, which tints
  /// the picture with a colored layer.
  multiply,

  /// Inverts both colors, multiplies them and inverts the result: the result
  /// is never darker than either of them. Black leaves the picture as it is,
  /// so a flame, a light leak or a film burn recorded against black adds only
  /// its light.
  screen,

  /// Multiplies the dark parts of the picture and screens its light parts, so
  /// the layer adds contrast and color while the picture's own highlights and
  /// shadows stay.
  overlay,

  /// A gentler [overlay]: a light layer brightens the picture and a dark one
  /// darkens it, as a diffuse spotlight would.
  softLight,

  /// Keeps the darker of the two colors.
  darken,

  /// Keeps the lighter of the two colors.
  lighten,

  /// Adds the colors, up to white. Brighter than [screen]: a light layer
  /// quickly burns the picture out.
  add,

  /// Subtracts the darker of the two colors from the lighter one. Black
  /// leaves the picture as it is and white inverts it.
  difference;

  /// The Flutter [BlendMode] that paints a layer as this mode does.
  BlendMode get blendMode => switch (this) {
    LayerBlendMode.normal => BlendMode.srcOver,
    LayerBlendMode.multiply => BlendMode.multiply,
    LayerBlendMode.screen => BlendMode.screen,
    LayerBlendMode.overlay => BlendMode.overlay,
    LayerBlendMode.softLight => BlendMode.softLight,
    LayerBlendMode.darken => BlendMode.darken,
    LayerBlendMode.lighten => BlendMode.lighten,
    LayerBlendMode.add => BlendMode.plus,
    LayerBlendMode.difference => BlendMode.difference,
  };

  /// The mode that renders as [mode] does, or `null` when none does.
  ///
  /// [BlendMode.srcOver] is [normal]; the other modes of Flutter with no
  /// counterpart here, such as [BlendMode.colorBurn], return `null`.
  static LayerBlendMode? fromBlendMode(BlendMode mode) {
    for (final value in values) {
      if (value.blendMode == mode) return value;
    }
    return null;
  }

  /// The mode stored under [name] by [Enum.name], or [normal] for `null` and
  /// for a name no mode has.
  static LayerBlendMode fromName(Object? name) =>
      name is String ? values.asNameMap()[name] ?? normal : normal;
}
