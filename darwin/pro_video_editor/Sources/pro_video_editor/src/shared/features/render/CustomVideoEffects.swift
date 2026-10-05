import CoreImage
import Foundation

/// The video effects an app implements itself, by id.
///
/// A Dart `CustomVideoEffect` names one of these ids; every render that carries
/// it asks the registered factory for a renderer and runs it on each frame
/// inside the effect's time range. Register before the first render, for
/// example in the app delegate:
///
/// ```swift
/// CustomVideoEffects.register("my.echo") { params in EchoRenderer(params) }
/// ```
///
/// A render that names an id nothing is registered under fails.
public enum CustomVideoEffects {
  /// Creates the renderer of one render from the Dart `CustomVideoEffect.params`.
  public typealias Factory = (_ params: [String: Any]) -> CustomVideoEffectRenderer

  private static let lock = NSLock()
  private static var factories: [String: Factory] = [:]

  /// Registers `factory` under `id`, replacing whatever was registered there.
  public static func register(_ id: String, factory: @escaping Factory) {
    precondition(!id.isEmpty, "A custom video effect id must not be empty")
    lock.lock()
    defer { lock.unlock() }
    factories[id] = factory
  }

  /// Removes what is registered under `id`; renders that already started keep it.
  public static func unregister(_ id: String) {
    lock.lock()
    defer { lock.unlock() }
    factories[id] = nil
  }

  /// Whether something is registered under `id`.
  public static func isRegistered(_ id: String) -> Bool {
    factory(for: id) != nil
  }

  static func factory(for id: String) -> Factory? {
    lock.lock()
    defer { lock.unlock() }
    return factories[id]
  }
}

/// Draws one custom video effect, frame by frame, with Core Image.
///
/// The compositor calls ``render(_:)`` on its own threads and may render
/// several frames at once, so keep the renderer free of mutable state: every
/// frame brings everything it needs, earlier frames included.
public protocol CustomVideoEffectRenderer: AnyObject {
  /// The earlier frames ``render(_:)`` receives, as how far each lies before
  /// the current frame, in microseconds of the rendered video. Read once,
  /// when the render starts.
  ///
  /// Earlier frames come from the same clip only: on the first frames of a
  /// clip, the ones further back than the clip has played are `nil`.
  var historyOffsetsUs: [Int64] { get }

  /// The size earlier frames are resampled to, relative to the video, from
  /// 0.05 to 1, so they look the way they do on Android, which keeps them at
  /// this size to save memory.
  var historyScale: Double { get }

  /// Returns `frame.image` with the effect applied. The result is cropped to
  /// the frame's extent.
  func render(_ frame: CustomVideoEffectFrame) -> CIImage
}

extension CustomVideoEffectRenderer {
  public var historyOffsetsUs: [Int64] { [] }
  public var historyScale: Double { 1 }
}

/// The frame a ``CustomVideoEffectRenderer`` draws.
public struct CustomVideoEffectFrame {
  /// The current frame, with its extent's origin at zero.
  public let image: CIImage

  /// Time of this frame on the rendered video, in microseconds.
  public let timeUs: Int64

  /// Time since the effect's start time, in microseconds.
  public let effectTimeUs: Int64

  /// One entry per ``CustomVideoEffectRenderer/historyOffsetsUs``, in the same
  /// order: the earlier frame that far back, with the same extent as
  /// ``image``, or `nil` when the clip has not played that long yet.
  public let history: [CIImage?]
}
