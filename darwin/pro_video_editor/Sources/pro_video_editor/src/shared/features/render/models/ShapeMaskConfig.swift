import Foundation

/// The shapes of the Dart `LayerShapeMaskShape`, by their wire names.
enum ShapeMaskShape: String, Sendable {
  case ellipse
  case rectangle
  case heart
  case star
  case triangle
  case diamond
  case hexagon
  case speechBubble
  case linear

  /// The shape named [name], or an ellipse for a name this version does not
  /// know.
  static func from(_ name: Any?) -> ShapeMaskShape {
    (name as? String).flatMap(ShapeMaskShape.init(rawValue:)) ?? .ellipse
  }
}

/// A shape mask at one moment, everything in fractions of the masked image,
/// mirroring a still Dart `LayerShapeMask`.
struct ShapeMaskState: Sendable, Equatable {
  let shape: ShapeMaskShape
  /// Centre of the shape, from the left and top edges.
  let centerX: Double
  let centerY: Double
  /// Size of the shape's box before it is turned.
  let width: Double
  let height: Double
  /// Clockwise turn around the centre, in radians.
  let rotation: Double
  /// Softness of the edge, in fractions of the image's shorter side.
  let feather: Double
  /// Roundness of a rectangle's corners, from 0 to 1.
  let cornerRadius: Double
  /// Whether the image shows outside the shape.
  let invert: Bool
  /// Whether the shape is mirrored across its vertical centre line before it
  /// is turned.
  let mirrored: Bool
}

/// The mask's centre, size, turn and softness at one point of the layer's
/// keyframe timeline, mirroring the Dart `LayerShapeMaskKeyframe`.
struct ShapeMaskKeyframeConfig: Sendable, Equatable {
  let timeUs: Int64
  var centerX: Double = 0.5
  var centerY: Double = 0.5
  var width: Double = 0.5
  var height: Double = 0.5
  var rotation: Double = 0
  var feather: Double = 0
  /// Easing toward the next keyframe (see `applyEasing`).
  var curve: String = "linear"

  static func fromArguments(_ args: [String: Any]) -> ShapeMaskKeyframeConfig {
    ShapeMaskKeyframeConfig(
      timeUs: (args["timeUs"] as? NSNumber)?.int64Value ?? 0,
      centerX: (args["x"] as? NSNumber)?.doubleValue ?? 0.5,
      centerY: (args["y"] as? NSNumber)?.doubleValue ?? 0.5,
      width: max(0, (args["width"] as? NSNumber)?.doubleValue ?? 0.5),
      height: max(0, (args["height"] as? NSNumber)?.doubleValue ?? 0.5),
      rotation: (args["rotation"] as? NSNumber)?.doubleValue ?? 0,
      feather: max(0, (args["feather"] as? NSNumber)?.doubleValue ?? 0),
      curve: args["curve"] as? String ?? "linear")
  }
}

/// A shape a layer shows through, drawn on every frame, mirroring the Dart
/// `LayerShapeMask`. Mirrors `ShapeMaskConfig` on Android.
struct ShapeMaskConfig: Sendable, Equatable {
  let shape: ShapeMaskShape
  var centerX: Double = 0.5
  var centerY: Double = 0.5
  var width: Double = 0.5
  var height: Double = 0.5
  var rotation: Double = 0
  var feather: Double = 0
  var cornerRadius: Double = 0
  var invert: Bool = false
  var mirrored: Bool = false
  /// How the mask changes over time, sorted by time and on the layer's
  /// keyframe timeline.
  var keyframes: [ShapeMaskKeyframeConfig] = []

  /// The mask at [keyframeTimeUs] on the layer's keyframe timeline: its own
  /// values without keyframes; with them, the first keyframe's before the
  /// first one, the last keyframe's after the last one, and in between a mix
  /// of the two around it along the earlier one's curve. Only the size and the
  /// softness are kept at 0 or more, so an elastic or bounce curve may
  /// overshoot.
  ///
  /// Mirrors `layerMaskKeyframeAt` in pro_image_editor, which the editor
  /// preview reads.
  func state(atUs keyframeTimeUs: Int64) -> ShapeMaskState {
    guard let first = keyframes.first, let last = keyframes.last else {
      return state(centerX, centerY, width, height, rotation, feather)
    }
    if keyframeTimeUs <= first.timeUs { return state(first) }
    if keyframeTimeUs >= last.timeUs { return state(last) }

    // The last keyframe at or before the time; both ends are ruled out above,
    // so a later one always exists.
    var index = 0
    for i in 1..<keyframes.count {
      if keyframes[i].timeUs > keyframeTimeUs { break }
      index = i
    }
    let from = keyframes[index]
    let to = keyframes[index + 1]
    let spanUs = to.timeUs - from.timeUs
    if spanUs <= 0 { return state(to) }

    let eased = applyEasing(
      Double(keyframeTimeUs - from.timeUs) / Double(spanUs), curve: from.curve)
    func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * eased }
    return state(
      mix(from.centerX, to.centerX),
      mix(from.centerY, to.centerY),
      max(0, mix(from.width, to.width)),
      max(0, mix(from.height, to.height)),
      mix(from.rotation, to.rotation),
      max(0, mix(from.feather, to.feather)))
  }

  private func state(_ keyframe: ShapeMaskKeyframeConfig) -> ShapeMaskState {
    state(
      keyframe.centerX, keyframe.centerY, keyframe.width, keyframe.height, keyframe.rotation,
      keyframe.feather)
  }

  private func state(
    _ centerX: Double, _ centerY: Double, _ width: Double, _ height: Double,
    _ rotation: Double, _ feather: Double
  ) -> ShapeMaskState {
    ShapeMaskState(
      shape: shape, centerX: centerX, centerY: centerY, width: width, height: height,
      rotation: rotation, feather: feather, cornerRadius: cornerRadius, invert: invert,
      mirrored: mirrored)
  }

  /// The mask in [raw], a map written by the Dart `LayerShapeMask.toMap`, or
  /// nil when there is none.
  static func from(_ raw: Any?) -> ShapeMaskConfig? {
    guard let args = raw as? [String: Any] else { return nil }
    let keyframes = ((args["keyframes"] as? [[String: Any]]) ?? [])
      .map { ShapeMaskKeyframeConfig.fromArguments($0) }
      .sorted { $0.timeUs < $1.timeUs }
    return ShapeMaskConfig(
      shape: ShapeMaskShape.from(args["shape"]),
      centerX: (args["x"] as? NSNumber)?.doubleValue ?? 0.5,
      centerY: (args["y"] as? NSNumber)?.doubleValue ?? 0.5,
      width: max(0, (args["width"] as? NSNumber)?.doubleValue ?? 0.5),
      height: max(0, (args["height"] as? NSNumber)?.doubleValue ?? 0.5),
      rotation: (args["rotation"] as? NSNumber)?.doubleValue ?? 0,
      feather: max(0, (args["feather"] as? NSNumber)?.doubleValue ?? 0),
      cornerRadius: min(1, max(0, (args["cornerRadius"] as? NSNumber)?.doubleValue ?? 0)),
      invert: args["invert"] as? Bool ?? false,
      mirrored: args["mirrored"] as? Bool ?? false,
      keyframes: keyframes)
  }
}
