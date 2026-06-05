import AVFoundation
import Foundation

class VideoMetadata {

    static func processVideo(
        inputPath: String,
        ext: String,
        checkStreamingOptimization: Bool = false
    ) async throws -> [String: Any] {

        let fileURL = URL(fileURLWithPath: inputPath)
        let asset = AVURLAsset(url: fileURL)

        var metadataDict: [String: Any] = [:]

        // --- File Properties ---
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: inputPath)
        if let fileSize = fileAttributes?[.size] as? Int64 {
            metadataDict["fileSize"] = fileSize
        }
        if let creationDate = fileAttributes?[.creationDate] as? Date {
            metadataDict["creationDate"] = Int64(creationDate.timeIntervalSince1970 * 1000)
        }

        // --- Core Video Properties (iOS 15+ or fallback) ---
        if #available(iOS 15.0, macOS 12.0, *) {
            await loadModernMetadata(asset: asset, into: &metadataDict)
        } else {
            loadLegacyMetadata(asset: asset, into: &metadataDict)
        }

        // --- Metadata & Tags ---
        if #available(iOS 15.0, macOS 12.0, *) {
            await loadModernCommonMetadata(asset: asset, into: &metadataDict)
        } else {
            loadLegacyCommonMetadata(asset: asset, into: &metadataDict)
        }

        // --- Streaming Optimization ---
        if checkStreamingOptimization {
            metadataDict["isOptimizedForStreaming"] = checkMoovBeforeMdat(at: inputPath)
        } else {
            metadataDict["isOptimizedForStreaming"] = false
        }

        return metadataDict
    }

    // MARK: - Modern iOS 15+ Path

    @available(iOS 15.0, macOS 12.0, *)
    private static func loadModernMetadata(asset: AVURLAsset, into dict: inout [String: Any]) async
    {
        do {
            let keys = ["tracks", "duration", "commonMetadata"]
            try await asset.loadValues(forKeys: keys)

            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)
            dict["durationMs"] = Int64(durationSeconds * 1000)

            let tracks = try await asset.load(.tracks)
            let videoTracks = tracks.filter { $0.mediaType == .video }

            if let videoTrack = videoTracks.first {
                let naturalSize = try await videoTrack.load(.naturalSize)
                let preferredTransform = try await videoTrack.load(.preferredTransform)
                let rotation = determineRotation(from: preferredTransform)
                dict["rotation"] = rotation

                if rotation == 90 || rotation == 270 {
                    dict["width"] = Int(naturalSize.height)
                    dict["height"] = Int(naturalSize.width)
                } else {
                    dict["width"] = Int(naturalSize.width)
                    dict["height"] = Int(naturalSize.height)
                }

                let frameRate = try await videoTrack.load(.nominalFrameRate)
                dict["frameRate"] = Double(frameRate)

                let estimatedBitRate = try await videoTrack.load(.estimatedDataRate)
                dict["bitrate"] = Int(estimatedBitRate)
            }
        } catch {
            // Fall back silently or log
        }
    }

    @available(iOS 15.0, macOS 12.0, *)
    private static func loadModernCommonMetadata(asset: AVURLAsset, into dict: inout [String: Any])
        async
    {
        do {
            let commonMetadata = try await asset.load(.commonMetadata)
            for item in commonMetadata {
                guard let key = item.commonKey?.rawValue else { continue }
                if let value = try? await item.load(.value) as? String {
                    switch key {
                    case AVMetadataKey.commonKeyTitle.rawValue: dict["title"] = value
                    case AVMetadataKey.commonKeyArtist.rawValue: dict["artist"] = value
                    case AVMetadataKey.commonKeyAlbumName.rawValue: dict["album"] = value
                    case AVMetadataKey.commonKeyAuthor.rawValue: dict["author"] = value
                    case AVMetadataKey.commonKeyDescription.rawValue: dict["description"] = value
                    default: break
                    }
                }
            }
        } catch {}
    }

    // MARK: - Legacy Path (iOS < 15)

    private static func loadLegacyMetadata(asset: AVURLAsset, into dict: inout [String: Any]) {
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        dict["durationMs"] = Int64(durationSeconds * 1000)

        let videoTracks = asset.tracks(withMediaType: .video)
        if let videoTrack = videoTracks.first {
            let naturalSize = videoTrack.naturalSize
            let preferredTransform = videoTrack.preferredTransform
            let rotation = determineRotation(from: preferredTransform)
            dict["rotation"] = rotation

            if rotation == 90 || rotation == 270 {
                dict["width"] = Int(naturalSize.height)
                dict["height"] = Int(naturalSize.width)
            } else {
                dict["width"] = Int(naturalSize.width)
                dict["height"] = Int(naturalSize.height)
            }

            dict["frameRate"] = Double(videoTrack.nominalFrameRate)
            dict["bitrate"] = Int(videoTrack.estimatedDataRate)
        }
    }

    private static func loadLegacyCommonMetadata(asset: AVURLAsset, into dict: inout [String: Any])
    {
        for item in asset.commonMetadata {
            guard let key = item.commonKey?.rawValue else { continue }
            if let value = item.value as? String {
                switch key {
                case AVMetadataKey.commonKeyTitle.rawValue: dict["title"] = value
                case AVMetadataKey.commonKeyArtist.rawValue: dict["artist"] = value
                case AVMetadataKey.commonKeyAlbumName.rawValue: dict["album"] = value
                case AVMetadataKey.commonKeyAuthor.rawValue: dict["author"] = value
                case AVMetadataKey.commonKeyDescription.rawValue: dict["description"] = value
                default: break
                }
            }
        }
    }

    // MARK: - Shared Helpers

    private static func determineRotation(from transform: CGAffineTransform) -> Int {
        if transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0 {
            return 90
        }
        if transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0 {
            return 270
        }
        if transform.a == -1.0 && transform.b == 0 && transform.c == 0 && transform.d == -1.0 {
            return 180
        }
        return 0
    }

    private static func checkMoovBeforeMdat(at path: String) -> Bool {
        // Fixed version with older API compatibility
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fileHandle.close() }

        var position: UInt64 = 0
        var moovPosition: UInt64? = nil
        var mdatPosition: UInt64? = nil

        let fileSize =
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0

        while position < fileSize {
            guard position + 8 <= fileSize else { break }

            do {
                try fileHandle.seek(toOffset: position)
            } catch { break }

            guard let headerData = try? fileHandle.readData(ofLength: 8), headerData.count == 8
            else {
                break
            }

            let sizeBytes = headerData.subdata(in: 0..<4)
            let atomSize = sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            let typeBytes = headerData.subdata(in: 4..<8)
            guard let atomType = String(data: typeBytes, encoding: .ascii) else { break }

            if atomType == "moov" {
                moovPosition = position
                if mdatPosition != nil { return false }
            } else if atomType == "mdat" {
                mdatPosition = position
                if moovPosition != nil { return true }
            }

            if moovPosition != nil && mdatPosition != nil { break }

            var actualSize: UInt64 = UInt64(atomSize)
            if atomSize == 1 {
                guard position + 16 <= fileSize else { break }
                guard let extData = try? fileHandle.readData(ofLength: 8), extData.count == 8 else {
                    break
                }
                let bytes = extData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
                actualSize = bytes
            } else if atomSize == 0 {
                break
            }

            position += actualSize
        }

        if let moov = moovPosition, let mdat = mdatPosition {
            return moov < mdat
        }
        return moovPosition != nil
    }

    static func checkAudioTrack(inputPath: String) async throws -> Bool {
        let fileURL = URL(fileURLWithPath: inputPath)
        let asset = AVURLAsset(url: fileURL)

        if #available(iOS 15.0, macOS 12.0, *) {
            let tracks = try await asset.load(.tracks)
            return !tracks.filter({ $0.mediaType == .audio }).isEmpty
        } else {
            return !asset.tracks(withMediaType: .audio).isEmpty
        }
    }
}
