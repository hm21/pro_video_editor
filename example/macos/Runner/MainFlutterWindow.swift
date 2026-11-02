import Cocoa
import CoreImage
import FlutterMacOS
import Photos
import pro_video_editor

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    ExampleVideoEffects.register()
    Task { @MainActor in
      let flutterViewController = FlutterViewController()
      let windowFrame = self.frame
      self.contentViewController = flutterViewController
      self.setFrame(windowFrame, display: true)

      RegisterGeneratedPlugins(registry: flutterViewController)
      PhotoLibraryTestHelper.register(with: flutterViewController.engine.binaryMessenger)
    }

    super.awakeFromNib()
  }
}

/// Adds the test videos of `integration_test/photo_library_test.dart` to the
/// photo library. A video added under the same name before is reused, so
/// repeated runs do not fill the library up.
enum PhotoLibraryTestHelper {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "pro_video_editor_example/photo_library", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "requestAccess":
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
          DispatchQueue.main.async { result(status == .authorized) }
        }
      case "addVideo":
        guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String,
          let name = args["name"] as? String
        else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "path and name", details: nil))
          return
        }
        addVideo(at: URL(fileURLWithPath: path), named: name) { identifier, error in
          DispatchQueue.main.async {
            if let identifier = identifier {
              result(identifier)
            } else {
              result(
                FlutterError(
                  code: "ADD_FAILED", message: error?.localizedDescription, details: nil))
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func addVideo(
    at file: URL, named name: String, completion: @escaping (String?, Error?) -> Void
  ) {
    if let existing = video(named: name) {
      completion(existing, nil)
      return
    }
    var identifier: String?
    PHPhotoLibrary.shared().performChanges({
      let options = PHAssetResourceCreationOptions()
      options.originalFilename = name
      let request = PHAssetCreationRequest.forAsset()
      request.addResource(with: .video, fileURL: file, options: options)
      identifier = request.placeholderForCreatedAsset?.localIdentifier
    }) { success, error in
      completion(success ? identifier : nil, error)
    }
  }

  private static func video(named name: String) -> String? {
    var match: String?
    PHAsset.fetchAssets(with: .video, options: nil).enumerateObjects { asset, _, stop in
      if PHAssetResource.assetResources(for: asset).contains(where: {
        $0.originalFilename == name
      }) {
        match = asset.localIdentifier
        stop.pointee = true
      }
    }
    return match
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
