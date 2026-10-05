import CoreImage
import Flutter
import UIKit
import pro_video_editor

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ExampleVideoEffects.register()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

/// Custom video effects of the example app, which
/// `integration_test/custom_video_effect_test.dart` renders.
enum ExampleVideoEffects {
  /// Inverts the colors, mixed in by the `amount` param (0–1, default 1).
  static let invert = "example.invert"

  /// Shows the frame from `delayMs` (default 500) earlier instead of the current one.
  static let delay = "example.delay"

  static func register() {
    CustomVideoEffects.register(invert) { params in InvertEffect(params) }
    CustomVideoEffects.register(delay) { params in DelayEffect(params) }
  }
}

private final class InvertEffect: CustomVideoEffectRenderer {
  private let amount: Double

  init(_ params: [String: Any]) {
    amount = (params["amount"] as? NSNumber)?.doubleValue ?? 1
  }

  func render(_ frame: CustomVideoEffectFrame) -> CIImage {
    let inverted = frame.image.applyingFilter("CIColorInvert")
    return inverted.applyingFilter(
      "CIDissolveTransition",
      parameters: [kCIInputTargetImageKey: frame.image, kCIInputTimeKey: 1 - amount]
    )
  }
}

private final class DelayEffect: CustomVideoEffectRenderer {
  let historyOffsetsUs: [Int64]

  init(_ params: [String: Any]) {
    historyOffsetsUs = [Int64((params["delayMs"] as? NSNumber)?.intValue ?? 500) * 1000]
  }

  func render(_ frame: CustomVideoEffectFrame) -> CIImage {
    // Until the clip has played that long, there is no earlier frame.
    (frame.history.first ?? nil) ?? frame.image
  }
}
