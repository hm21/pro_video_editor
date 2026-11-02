import AVFoundation
import Foundation
import Photos

/// Resolves photo library videos — `ph://<localIdentifier>` URLs, such as the
/// `ph:///` URIs `file_picker` returns — to files AVFoundation can open.
///
/// A video is read in place: `requestAVAsset` hands out the file the photo
/// library keeps, downloading it from iCloud first if needed, and lets the app
/// read it from then on, so nothing is copied. Only a video Photos plays from
/// a composition, a slow-motion video with its slowed section, has no such
/// file; it is exported once into the temporary directory, like Android
/// copies a content URI it cannot seek.
///
/// `EditorVideo` resolves a photo library video before it hands it to any
/// other call, so the pipelines only ever see file paths.
///
/// The plugin never asks for photo library access itself. Without it, or with
/// limited access that leaves the video out, the video is not found. If the
/// app has not asked yet, the system shows its prompt on the first lookup,
/// which still fails. Without `NSPhotoLibraryUsageDescription` in the app's
/// Info.plist, every lookup fails before it reaches the photo library.
actor PhotoLibraryVideo {
  static let shared = PhotoLibraryVideo()

  static let urlPrefix = "ph://"

  /// Where slow-motion videos are exported to. An export is named after its
  /// video's identifier and modification date, so it is reused across
  /// launches until the video is edited in Photos, and the system clears the
  /// directory.
  static var exportDirectory: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("pro_video_editor_photo_library", isDirectory: true)
  }

  private struct Resolved {
    let modificationDate: Date?
    let url: URL
  }

  private var resolved: [String: Resolved] = [:]
  private var inFlight: [String: Task<URL, Error>] = [:]

  static func isPhotoLibraryURL(_ path: String) -> Bool {
    path.hasPrefix(urlPrefix)
  }

  /// The local identifier in `ph://<id>` or `ph:///<id>`. The three-slash form
  /// keeps the identifier out of the URL's host, which would be lowercased.
  static func localIdentifier(in url: String) -> String {
    String(url.dropFirst(urlPrefix.count).drop(while: { $0 == "/" }))
  }

  /// The file `url` is read from.
  ///
  /// The video is looked up on every call, so one edited in Photos meanwhile
  /// resolves to its new version. Calls for the same video while it is still
  /// being resolved share that request, so a slow-motion video is never
  /// exported twice at once.
  func resolve(_ url: String) async throws -> URL {
    let identifier = Self.localIdentifier(in: url)
    let asset = try Self.fetchVideo(identifier)
    let modificationDate = asset.modificationDate

    if let known = resolved[identifier], known.modificationDate == modificationDate,
      FileManager.default.fileExists(atPath: known.url.path)
    {
      return known.url
    }
    if let pending = inFlight[identifier] {
      return try await pending.value
    }

    let task = Task {
      try await Self.locate(asset, identifier: identifier, modificationDate: modificationDate)
    }
    inFlight[identifier] = task
    defer { inFlight[identifier] = nil }

    let file = try await task.value
    resolved[identifier] = Resolved(modificationDate: modificationDate, url: file)
    return file
  }

  private static func fetchVideo(_ identifier: String) throws -> PHAsset {
    // Without the key, the system ends the app on the first photo library
    // access instead of failing the call.
    guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil
    else {
      throw failure(
        code: 5,
        "Reading photo library videos needs NSPhotoLibraryUsageDescription in the app's Info.plist."
      )
    }
    guard
      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        .firstObject
    else {
      throw failure(
        code: 1, "No photo library video has the identifier \(identifier).\(accessHint())")
    }
    guard asset.mediaType == .video else {
      throw failure(code: 2, "The photo library asset \(identifier) is not a video.")
    }
    return asset
  }

  /// Why a video may be missing, for the error message.
  private static func accessHint() -> String {
    let status: PHAuthorizationStatus
    if #available(iOS 14.0, macOS 11.0, *) {
      status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    } else {
      status = PHPhotoLibrary.authorizationStatus()
    }
    switch status {
    case .authorized:
      return ""
    case .notDetermined:
      return " The app has not asked for photo library access yet; ask before reading the video."
    case .denied, .restricted:
      return " The app has no photo library access."
    default:
      return " The app has limited photo library access, which may leave the video out."
    }
  }

  private static func locate(
    _ asset: PHAsset, identifier: String, modificationDate: Date?
  ) async throws -> URL {
    let (avAsset, audioMix) = try await requestAVAsset(asset, identifier: identifier)
    // Only a local file can be handed on as a path; anything else, such as a
    // stream, is exported like a composition.
    if let urlAsset = avAsset as? AVURLAsset, urlAsset.url.isFileURL {
      return urlAsset.url
    }
    return try await export(
      avAsset, audioMix: audioMix, identifier: identifier, modificationDate: modificationDate)
  }

  private static func requestAVAsset(
    _ asset: PHAsset, identifier: String
  ) async throws -> (AVAsset, AVAudioMix?) {
    let options = PHVideoRequestOptions()
    options.version = .current
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true

    return try await withCheckedThrowingContinuation { continuation in
      PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
        avAsset, audioMix, info in
        if let avAsset = avAsset {
          continuation.resume(returning: (avAsset, audioMix))
        } else if let error = info?[PHImageErrorKey] as? Error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(
            throwing: failure(code: 3, "Photos returned no video for \(identifier)."))
        }
      }
    }
  }

  /// Exports a video Photos plays from a composition, as it plays there, or
  /// hands out as anything but a local file.
  private static func export(
    _ composition: AVAsset, audioMix: AVAudioMix?, identifier: String, modificationDate: Date?
  ) async throws -> URL {
    let fileManager = FileManager.default
    let stem = identifier.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
    let version = modificationDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
    let name = "\(String(stem))_\(version)"
    let file = exportDirectory.appendingPathComponent("\(name).mov")
    if fileManager.fileExists(atPath: file.path) {
      return file
    }

    try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    // Earlier versions of the video and an export cut short by the app ending.
    let stale = (try? fileManager.contentsOfDirectory(atPath: exportDirectory.path)) ?? []
    for entry in stale where entry.hasPrefix("\(String(stem))_") {
      try? fileManager.removeItem(at: exportDirectory.appendingPathComponent(entry))
    }

    guard
      let session = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality)
        ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
    else {
      throw failure(code: 4, "The photo library video \(identifier) cannot be exported.")
    }
    session.audioMix = audioMix

    PluginLog.print(
      "🎞️ Exporting photo library video \(identifier), which Photos plays from a composition")
    let partial = exportDirectory.appendingPathComponent("\(name)-partial.mov")
    try await SetupStageExport.run(
      session, to: partial, as: .mov,
      diagnostics: PhotoLibraryExportDiagnostics(identifier: identifier),
      label: "PhotoLibraryExport", failureDomain: "PhotoLibraryVideo")
    try fileManager.moveItem(at: partial, to: file)
    return file
  }

  private static func failure(code: Int, _ message: String) -> NSError {
    NSError(
      domain: "PhotoLibraryVideo", code: code,
      userInfo: [NSLocalizedDescriptionKey: message])
  }
}

struct PhotoLibraryExportDiagnostics: ExportDiagnostics {
  /// Local identifier of the video being exported.
  let identifier: String

  func timeoutMessage(seconds: Int, progress: Double) -> String {
    String(
      format: "Photo library export timed out after %ds [progress=%.2f identifier=%@]",
      seconds, progress, identifier)
  }

  func stallMessage(seconds: Int, progress: Double) -> String {
    String(
      format: "Photo library export stalled after %ds with no progress [progress=%.2f identifier=%@]",
      seconds, progress, identifier)
  }
}
