import CoreGraphics
import Foundation
import ImageIO

#if os(macOS)
  import FlutterMacOS
#else
  import Flutter
#endif

/// Where a caller-supplied encoded image keeps its bytes.
///
/// Bytes that arrive over the method channel are already resident and stay
/// there; a file is handed to ImageIO as a URL, so nothing but the decoded
/// image is held. A stop-motion sequence is the case that makes the difference
/// matter — a few hundred phone photos passed as bytes at once is hundreds of
/// megabytes before any of them is decoded.
///
/// Mirrors Android's `EncodedImage`. Modelling the choice as a sum type rather
/// than two optionals is deliberate: "neither is set" and "both are set" are
/// not states any caller has to think about.
enum EncodedImage: Sendable, Equatable {
  /// Encoded bytes already in memory.
  case bytes(Data)

  /// An encoded image on disk, read only while it is being decoded.
  case file(String)

  /// Reads an image source out of a channel argument map, preferring the
  /// on-disk path Dart sends for a file-backed image over inline bytes.
  ///
  /// Returns nil when the map carries neither, which every caller reads as
  /// "no image here".
  static func from(
    _ args: [String: Any], pathKey: String, dataKey: String
  ) -> EncodedImage? {
    if let path = args[pathKey] as? String, !path.isEmpty {
      return .file(path)
    }

    let data: Data?
    if let flutterData = args[dataKey] as? FlutterStandardTypedData {
      data = flutterData.data
    } else {
      data = args[dataKey] as? Data
    }

    guard let data = data, !data.isEmpty else { return nil }
    return .bytes(data)
  }

  /// An ImageIO source over this image.
  ///
  /// A file becomes a URL-backed source, so ImageIO reads it as it decodes
  /// instead of the caller copying it onto the heap first — which is the whole
  /// point of carrying a path.
  var imageSource: CGImageSource? {
    switch self {
    case .bytes(let data):
      return CGImageSourceCreateWithData(data as CFData, nil)
    case .file(let path):
      return CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
    }
  }

  /// The encoded bytes in one contiguous buffer.
  ///
  /// A file is *mapped* rather than copied, so its pages stay with the kernel's
  /// file cache instead of growing the app's footprint. Only for a consumer
  /// that genuinely needs one buffer — anything decoding pixels goes through
  /// [imageSource].
  var data: Data? {
    switch self {
    case .bytes(let data):
      return data
    case .file(let path):
      return try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    }
  }

  /// Names this source for a log line or an error message.
  var describe: String {
    switch self {
    case .bytes(let data): return "\(data.count) bytes"
    case .file(let path): return path
    }
  }
}
