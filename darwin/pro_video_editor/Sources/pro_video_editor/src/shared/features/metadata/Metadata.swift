import AVFoundation
import Foundation

class VideoMetadata {

  static func processVideo(
    inputPath: String,
    ext: String,
    checkStreamingOptimization: Bool = false
  ) async throws -> [String: Any] {
    let tempFileURL = URL(fileURLWithPath: inputPath)
    let asset = AVURLAsset(url: tempFileURL)

    // MARK: - File Properties

    let fileSize: Int64
    do {
      let attr = try FileManager.default.attributesOfItem(atPath: tempFileURL.path)
      fileSize = attr[.size] as? Int64 ?? 0
    } catch {
      return ["error": "Failed to get file size: \(error.localizedDescription)"]
    }

    // MARK: - Duration Extraction

    let duration: CMTime
    if #available(iOS 15.0, macOS 12.0, *) {
      duration = try await asset.load(.duration)
    } else {
      duration = asset.duration
    }
    let durationMs = CMTimeGetSeconds(duration) * 1000.0

    // MARK: - Audio Track Duration

    var audioDurationMs: Double? = nil
    if #available(iOS 15.0, macOS 12.0, *) {
      let audioTracks = try await asset.loadTracks(withMediaType: .audio)
      if let audioTrack = audioTracks.first {
        let audioTimeRange = try await audioTrack.load(.timeRange)
        audioDurationMs = CMTimeGetSeconds(audioTimeRange.duration) * 1000.0
      }
    } else {
      if let audioTrack = asset.tracks(withMediaType: .audio).first {
        audioDurationMs = CMTimeGetSeconds(audioTrack.timeRange.duration) * 1000.0
      }
    }

    // MARK: - Video Track Properties

    var numericMetadata: [String: Int] = [
      "width": 0,
      "height": 0,
      "rotation": 0,
      "bitrate": 0,
    ]
    var frameRate: Double? = nil

    if durationMs > 0 {
      let fileSizeBits = fileSize * 8
      numericMetadata["bitrate"] = Int(Double(fileSizeBits) * 1000 / durationMs)
    }

    if #available(iOS 15.0, macOS 12.0, *) {
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      if let track = videoTracks.first {
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformedSize = size.applying(transform)
        numericMetadata["width"] = Int(abs(transformedSize.width))
        numericMetadata["height"] = Int(abs(transformedSize.height))
        let angle = atan2(transform.b, transform.a)
        numericMetadata["rotation"] = (Int(round(angle * 180 / .pi)) + 360) % 360
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        if nominalFrameRate > 0 { frameRate = Double(nominalFrameRate) }
      }
    } else {
      if let track = asset.tracks(withMediaType: .video).first {
        let size = track.naturalSize.applying(track.preferredTransform)
        numericMetadata["width"] = Int(abs(size.width))
        numericMetadata["height"] = Int(abs(size.height))
        let angle = atan2(track.preferredTransform.b, track.preferredTransform.a)
        numericMetadata["rotation"] = (Int(round(angle * 180 / .pi)) + 360) % 360
        if track.nominalFrameRate > 0 { frameRate = Double(track.nominalFrameRate) }
      }
    }

    // MARK: - Descriptive Metadata

    let textMetadataKeys = [
      "title": "title",
      "artist": "artist",
      "author": "author",
      "album": "albumName",
      "albumArtist": "albumArtist",
    ]
    var textMetadata: [String: String] = [:]
    var latitude: Double? = nil
    var longitude: Double? = nil
    var cameraMake: String = ""
    var cameraModel: String = ""

    if #available(iOS 15.0, macOS 12.0, *) {
      let metadataItems = try await asset.load(.commonMetadata)
      for (resultKey, metadataKey) in textMetadataKeys {
        textMetadata[resultKey] = try await loadMetadataString(
          from: metadataItems, key: metadataKey)
      }

      if let locationItem = metadataItems.first(where: {
        $0.commonKey?.rawValue == "location"
      }) {
        if let locationString = try? await locationItem.load(.stringValue) {
          let coords = parseLocationString(locationString)
          latitude = coords.latitude
          longitude = coords.longitude
        }
      }

      let allMetadata = try await asset.load(.metadata)
      for item in allMetadata {
        if let key = item.key as? String {
          let keyLower = key.lowercased()
          if key == "com.apple.quicktime.make" {
            cameraMake = try await item.load(.stringValue) ?? ""
          } else if key == "com.apple.quicktime.model" {
            cameraModel = try await item.load(.stringValue) ?? ""
          } else if latitude == nil
            && (key == "com.apple.quicktime.location.ISO6709"
              || keyLower.contains("location") || keyLower.contains("gps")
              || key.contains("©xyz"))
          {
            if let locationString = try? await item.load(.stringValue) {
              let coords = parseLocationString(locationString)
              latitude = coords.latitude
              longitude = coords.longitude
            }
            if latitude == nil, let locationData = try? await item.load(.dataValue) {
              let coords = parseLocationData(locationData)
              latitude = coords.latitude
              longitude = coords.longitude
            }
          }
        }
        if latitude == nil, let identifier = item.identifier {
          let idRaw = identifier.rawValue.lowercased()
          if identifier == .quickTimeMetadataLocationISO6709
            || identifier == .identifier3GPUserDataLocation
            || idRaw.contains("location") || idRaw.contains("gps")
            || idRaw.contains("%a9xyz") || idRaw.contains("©xyz")
          {
            if let locationString = try? await item.load(.stringValue) {
              let coords = parseLocationString(locationString)
              latitude = coords.latitude
              longitude = coords.longitude
            }
            if latitude == nil, let locationData = try? await item.load(.dataValue) {
              let coords = parseLocationData(locationData)
              latitude = coords.latitude
              longitude = coords.longitude
            }
          }
          if cameraModel.isEmpty && idRaw.contains("auth") {
            if let model = try? await item.load(.stringValue) { cameraModel = model }
          }
        }
      }

      if latitude == nil {
        let qtMetadata = AVMetadataItem.metadataItems(
          from: allMetadata, filteredByIdentifier: .quickTimeMetadataLocationISO6709)
        if let locationItem = qtMetadata.first,
          let locationString = try? await locationItem.load(.stringValue)
        {
          let coords = parseLocationString(locationString)
          latitude = coords.latitude
          longitude = coords.longitude
        }
      }
      if latitude == nil {
        let threeGPMetadata = AVMetadataItem.metadataItems(
          from: allMetadata, filteredByIdentifier: .identifier3GPUserDataLocation)
        if let locationItem = threeGPMetadata.first,
          let locationString = try? await locationItem.load(.stringValue)
        {
          let coords = parseLocationString(locationString)
          latitude = coords.latitude
          longitude = coords.longitude
        }
      }
    } else {
      let metadataItems = asset.commonMetadata
      for (resultKey, metadataKey) in textMetadataKeys {
        textMetadata[resultKey] =
          metadataItems.first(where: { $0.commonKey?.rawValue == metadataKey })?
          .stringValue ?? ""
      }
      if let locationItem = metadataItems.first(where: {
        $0.commonKey?.rawValue == "location"
      }),
        let locationString = locationItem.stringValue
      {
        let coords = parseLocationString(locationString)
        latitude = coords.latitude
        longitude = coords.longitude
      }
      let allMetadata = asset.metadata
      for item in allMetadata {
        if let key = item.key as? String {
          let keyLower = key.lowercased()
          if key == "com.apple.quicktime.make" {
            cameraMake = item.stringValue ?? ""
          } else if key == "com.apple.quicktime.model" {
            cameraModel = item.stringValue ?? ""
          } else if latitude == nil
            && (key == "com.apple.quicktime.location.ISO6709"
              || keyLower.contains("location") || keyLower.contains("gps")
              || key.contains("©xyz"))
          {
            if let locationString = item.stringValue {
              let coords = parseLocationString(locationString)
              latitude = coords.latitude
              longitude = coords.longitude
            }
            if latitude == nil, let locationData = item.dataValue {
              let coords = parseLocationData(locationData)
              latitude = coords.latitude
              longitude = coords.longitude
            }
          }
        }
        if latitude == nil, let identifier = item.identifier {
          let idRaw = identifier.rawValue.lowercased()
          if identifier == .quickTimeMetadataLocationISO6709
            || identifier == .identifier3GPUserDataLocation
            || idRaw.contains("location") || idRaw.contains("gps")
            || idRaw.contains("%a9xyz") || idRaw.contains("©xyz")
          {
            if let locationString = item.stringValue {
              let coords = parseLocationString(locationString)
              latitude = coords.latitude
              longitude = coords.longitude
            }
            if latitude == nil, let locationData = item.dataValue {
              let coords = parseLocationData(locationData)
              latitude = coords.latitude
              longitude = coords.longitude
            }
          }
          if cameraModel.isEmpty && idRaw.contains("auth") {
            if let model = item.stringValue { cameraModel = model }
          }
        }
      }
      if latitude == nil {
        let qtMetadata = AVMetadataItem.metadataItems(
          from: allMetadata, filteredByIdentifier: .quickTimeMetadataLocationISO6709)
        if let locationItem = qtMetadata.first,
          let locationString = locationItem.stringValue
        {
          let coords = parseLocationString(locationString)
          latitude = coords.latitude
          longitude = coords.longitude
        }
      }
      if latitude == nil {
        let threeGPMetadata = AVMetadataItem.metadataItems(
          from: allMetadata, filteredByIdentifier: .identifier3GPUserDataLocation)
        if let locationItem = threeGPMetadata.first,
          let locationString = locationItem.stringValue
        {
          let coords: (latitude: Double?, longitude: Double?) = parseLocationString(locationString)
          latitude = coords.latitude
          longitude = coords.longitude
        }
      }
    }

    // MARK: - Creation Date

    var dateStr = ""
    if #available(iOS 15.0, macOS 12.0, *) {
      if let creationItem = try? await asset.load(.creationDate),
        let creationDate = try? await creationItem.load(.dateValue)
      {
        dateStr = ISO8601DateFormatter().string(from: creationDate)
      }
    } else if #available(iOS 13.4, macOS 10.15.4, *) {
      if let creationItem = asset.creationDate,
        let creationDate = creationItem.dateValue
      {
        dateStr = ISO8601DateFormatter().string(from: creationDate)
      }
    }
    if dateStr.isEmpty {
      if let attr = try? FileManager.default.attributesOfItem(atPath: tempFileURL.path),
        let fileCreationDate = attr[.creationDate] as? Date
      {
        dateStr = ISO8601DateFormatter().string(from: fileCreationDate)
      }
    }

    // MARK: - Return Metadata Dictionary

    var metadataDict: [String: Any] = [
      "fileSize": fileSize,
      "duration": durationMs,
      "width": numericMetadata["width"] ?? 0,
      "height": numericMetadata["height"] ?? 0,
      "rotation": numericMetadata["rotation"] ?? 0,
      "bitrate": numericMetadata["bitrate"] ?? 0,
      "title": textMetadata["title"] ?? "",
      "artist": textMetadata["artist"] ?? "",
      "author": textMetadata["author"] ?? "",
      "album": textMetadata["album"] ?? "",
      "albumArtist": textMetadata["albumArtist"] ?? "",
      "date": dateStr,
      "cameraMake": cameraMake,
      "cameraModel": cameraModel,
    ]

    if let audioDuration = audioDurationMs { metadataDict["audioDuration"] = audioDuration }
    if let lat = latitude { metadataDict["latitude"] = lat }
    if let lon = longitude { metadataDict["longitude"] = lon }
    if let fps = frameRate { metadataDict["frameRate"] = fps }

    if checkStreamingOptimization {
      #if os(iOS) || os(macOS)
        if #available(iOS 13.4, macOS 10.15.4, *),
          let isOptimized = Self.checkStreamingOptimization(url: tempFileURL)
        {
          metadataDict["isOptimizedForStreaming"] = isOptimized
        }
      #endif
    }

    return metadataDict
  }

  // MARK: - Audio Track Check

  static func checkAudioTrack(inputPath: String) async throws -> Bool {
    let tempFileURL = URL(fileURLWithPath: inputPath)
    let asset = AVURLAsset(url: tempFileURL)
    if #available(iOS 15.0, macOS 12.0, *) {
      let audioTracks = try await asset.loadTracks(withMediaType: .audio)
      return !audioTracks.isEmpty
    } else {
      return !asset.tracks(withMediaType: .audio).isEmpty
    }
  }

  // MARK: - Helper Methods

  @available(iOS 15.0, macOS 12.0, *)
  private static func loadMetadataString(from metadata: [AVMetadataItem], key: String)
    async throws -> String
  {
    if let item = metadata.first(where: { $0.commonKey?.rawValue == key }) {
      return try await item.load(.stringValue) ?? ""
    }
    return ""
  }

  private static func parseLocationString(_ locationString: String) -> (
    latitude: Double?, longitude: Double?
  ) {
    let cleaned = locationString.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    var latitude: Double? = nil
    var longitude: Double? = nil
    var signPositions: [Int] = []
    for (index, char) in cleaned.enumerated() {
      if char == "+" || char == "-" { signPositions.append(index) }
    }
    if signPositions.count >= 2 {
      let latStartIndex = cleaned.index(cleaned.startIndex, offsetBy: signPositions[0])
      let lonStartIndex = cleaned.index(cleaned.startIndex, offsetBy: signPositions[1])
      latitude = Double(String(cleaned[latStartIndex..<lonStartIndex]))
      longitude = Double(String(cleaned[lonStartIndex...]))
    }
    return (latitude, longitude)
  }

  private static func parseLocationData(_ data: Data) -> (latitude: Double?, longitude: Double?) {
    if let locationString = String(data: data, encoding: .utf8) {
      let coords = parseLocationString(locationString)
      if coords.latitude != nil { return coords }
    }
    if let locationString = String(data: data, encoding: .utf16) {
      let coords = parseLocationString(locationString)
      if coords.latitude != nil { return coords }
    }
    if data.count >= 8 {
      let latBytes = data.subdata(in: 0..<4)
      let lonBytes = data.subdata(in: 4..<8)
      let lat = latBytes.withUnsafeBytes { $0.load(as: Float32.self) }
      let lon = lonBytes.withUnsafeBytes { $0.load(as: Float32.self) }
      if lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 {
        return (Double(lat), Double(lon))
      }
      let latBE = Float32(
        bitPattern: UInt32(bigEndian: latBytes.withUnsafeBytes { $0.load(as: UInt32.self) })
      )
      let lonBE = Float32(
        bitPattern: UInt32(bigEndian: lonBytes.withUnsafeBytes { $0.load(as: UInt32.self) })
      )
      if latBE >= -90 && latBE <= 90 && lonBE >= -180 && lonBE <= 180 {
        return (Double(latBE), Double(lonBE))
      }
    }
    return (nil, nil)
  }

  // MARK: - Streaming Optimization Check

  @available(iOS 13.4, macOS 10.15.4, *)
  private static func checkStreamingOptimization(url: URL) -> Bool? {
    let ext = url.pathExtension.lowercased()
    guard ["mp4", "mov", "m4v", "m4a"].contains(ext) else { return nil }
    guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fileHandle.close() }

    var moovPosition: UInt64? = nil
    var mdatPosition: UInt64? = nil
    var position: UInt64 = 0

    while true {
      guard let headerData = try? fileHandle.read(upToCount: 8), headerData.count == 8 else {
        break
      }
      let atomSize =
        UInt64(headerData[0]) << 24 | UInt64(headerData[1]) << 16
        | UInt64(headerData[2]) << 8 | UInt64(headerData[3])
      let atomType = String(data: headerData[4..<8], encoding: .ascii) ?? ""

      switch atomType {
      case "moov": moovPosition = position
      case "mdat": mdatPosition = position
      default: break
      }

      if let moov = moovPosition, let mdat = mdatPosition { return moov < mdat }

      var actualSize: UInt64
      if atomSize == 1 {
        guard let extData = try? fileHandle.read(upToCount: 8), extData.count == 8 else {
          break
        }
        actualSize = (0..<8).reduce(0) { $0 | UInt64(extData[$1]) << (56 - $1 * 8) }
      } else if atomSize == 0 {
        break
      } else {
        actualSize = atomSize
      }

      position += actualSize
      do { try fileHandle.seek(toOffset: position) } catch { break }
    }

    if moovPosition != nil && mdatPosition == nil { return true }
    if moovPosition == nil && mdatPosition != nil { return false }
    return nil
  }
}
