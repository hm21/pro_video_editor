import AVFoundation
import CoreImage
import Foundation

/// One custom video effect of a render: the id its implementation is
/// registered under, its settings, and its time range on the rendered video.
///
/// Mirrors the Dart `CustomVideoEffect`. The params are the property-list
/// values the platform channel decoded, never mutated, hence `@unchecked`.
struct CustomVideoEffectConfig: @unchecked Sendable {
  let id: String
  let params: [String: Any]
  let startUs: Int64?
  let endUs: Int64?

  /// Whether the effect draws the frame at `timeUs`.
  func isActive(atUs timeUs: Int64) -> Bool {
    (startUs == nil || timeUs >= startUs!) && (endUs == nil || timeUs < endUs!)
  }

  /// Parses one entry of the `customEffects` argument, or nil without an id.
  static func fromArguments(_ args: [String: Any]) -> CustomVideoEffectConfig? {
    guard let id = args["id"] as? String, !id.isEmpty else { return nil }
    return CustomVideoEffectConfig(
      id: id,
      params: args["params"] as? [String: Any] ?? [:],
      startUs: (args["startUs"] as? NSNumber)?.int64Value,
      endUs: (args["endUs"] as? NSNumber)?.int64Value
    )
  }
}

/// A custom effect as one render runs it: its renderer, and the composition
/// tracks that carry the earlier frames it asked for.
final class CustomVideoEffectStage: @unchecked Sendable {
  let config: CustomVideoEffectConfig
  let renderer: CustomVideoEffectRenderer

  /// The renderer's history offsets, read once.
  let historyOffsetsUs: [Int64]

  /// The renderer's history scale, clamped to 0.05...1.
  let historyScale: CGFloat

  /// The track showing the video delayed by each of `historyOffsetsUs`, in
  /// the same order. Written once during setup, before the composition is
  /// handed to AVFoundation, and only read from the compositing threads.
  var historyTrackIDs: [CMPersistentTrackID]

  init(config: CustomVideoEffectConfig, renderer: CustomVideoEffectRenderer) {
    self.config = config
    self.renderer = renderer
    self.historyOffsetsUs = renderer.historyOffsetsUs
    self.historyScale = CGFloat(min(1, max(0.05, renderer.historyScale)))
    self.historyTrackIDs = Array(
      repeating: kCMPersistentTrackID_Invalid, count: historyOffsetsUs.count)
  }
}
