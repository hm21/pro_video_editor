import AVFoundation
import CoreMedia
import Foundation

/// Utility class for extracting media information from video and audio files.
///
/// Provides methods to extract duration, channel count, and sample rate
/// using AVFoundation APIs across iOS and macOS environments.
internal class MediaInfoExtractor {

    // MARK: - Duration Extraction

    /// Retrieves video duration from file.
    ///
    /// - Parameter videoPath: Absolute path to video file
    /// - Returns: Duration in microseconds, or 0 if not found
    static func getVideoDuration(_ videoPath: String) async -> Int64 {
        let url = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            PluginLog.print("❌ Video file does not exist: \(videoPath)")
            return 0
        }

        let asset = AVURLAsset(url: url)

        do {
            let duration: CMTime
            #if os(macOS)
            if #available(macOS 13.0, *) {
                duration = try await asset.load(.duration)
            } else {
                duration = asset.duration
            }
            #elseif os(iOS)
            if #available(iOS 15.0, *) {
                duration = try await asset.load(.duration)
            } else {
                duration = asset.duration
            }
            #endif

            guard duration.seconds.isFinite else {
                return 0
            }

            return Int64(duration.seconds * 1_000_000)
        } catch {
            PluginLog.print("❌ Failed to get video duration for \(videoPath): \(error.localizedDescription)")
            return 0
        }
    }

    /// Retrieves audio duration from file.
    ///
    /// - Parameter audioPath: Absolute path to audio file
    /// - Returns: Duration in microseconds, or 0 if not found
    static func getAudioDuration(_ audioPath: String) async -> Int64 {
        let url = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            PluginLog.print("❌ Audio file does not exist: \(audioPath)")
            return 0
        }

        let asset = AVURLAsset(url: url)

        do {
            let duration: CMTime
            #if os(macOS)
            if #available(macOS 13.0, *) {
                duration = try await asset.load(.duration)
            } else {
                duration = asset.duration
            }
            #elseif os(iOS)
            if #available(iOS 15.0, *) {
                duration = try await asset.load(.duration)
            } else {
                duration = asset.duration
            }
            #endif

            guard duration.seconds.isFinite else {
                return 0
            }

            let durationUs = Int64(duration.seconds * 1_000_000)
            PluginLog.print("🔍 Audio duration: \(durationUs / 1000) ms")
            return durationUs
        } catch {
            PluginLog.print("❌ Failed to get audio duration: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Audio Channel Detection

    /// Detects the number of audio channels in a video file.
    ///
    /// - Parameter videoPath: Absolute path to video file
    /// - Returns: Number of channels (1=mono, 2=stereo, 6=5.1), or nil if not found
    static func getAudioChannelCount(_ videoPath: String) async -> Int? {
        let url = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let asset = AVURLAsset(url: url)

        do {
            let tracks: [AVAssetTrack]
            #if os(macOS)
            if #available(macOS 13.0, *) {
                tracks = try await asset.loadTracks(withMediaType: .audio)
            } else {
                tracks = asset.tracks(withMediaType: .audio)
            }
            #elseif os(iOS)
            if #available(iOS 15.0, *) {
                tracks = try await asset.loadTracks(withMediaType: .audio)
            } else {
                tracks = asset.tracks(withMediaType: .audio)
            }
            #endif

            guard let audioTrack = tracks.first else {
                return nil
            }

            let formatDescriptions: [Any]
            #if os(macOS)
            if #available(macOS 13.0, *) {
                formatDescriptions = try await audioTrack.load(.formatDescriptions)
            } else {
                formatDescriptions = audioTrack.formatDescriptions
            }
            #elseif os(iOS)
            if #available(iOS 15.0, *) {
                formatDescriptions = try await audioTrack.load(.formatDescriptions)
            } else {
                formatDescriptions = audioTrack.formatDescriptions
            }
            #endif

            for description in formatDescriptions {
                let formatDesc = description as! CMFormatDescription
                if let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                    let channelCount = Int(basicDesc.pointee.mChannelsPerFrame)
                    PluginLog.print("🔍 File \(videoPath): \(channelCount) audio channels")
                    return channelCount
                }
            }

            return nil
        } catch {
            PluginLog.print("❌ Failed to detect audio channels for \(videoPath): \(error.localizedDescription)")
            return nil
        }
    }

    /// Detects sample rate of an audio file.
    ///
    /// - Parameter audioPath: Absolute path to audio file
    /// - Returns: Sample rate in Hz (e.g., 44100, 48000), or 0 if not found
    static func getAudioSampleRate(_ audioPath: String) async -> Int {
        let url = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }

        let asset = AVURLAsset(url: url)

        do {
            let tracks: [AVAssetTrack]
            #if os(macOS)
            if #available(macOS 13.0, *) {
                tracks = try await asset.loadTracks(withMediaType: .audio)
            } else {
                tracks = asset.tracks(withMediaType: .audio)
            }
            #elseif os(iOS)
            if #available(iOS 15.0, *) {
                tracks = try await asset.loadTracks(withMediaType: .audio)
            } else {
                tracks = asset.tracks(withMediaType: .audio)
            }
            #endif

            guard let audioTrack = tracks.first else {
                return 0
            }

            let formatDescriptions: [Any]
            #if os(macOS)
            if #available(macOS 13.0, *) {
                formatDescriptions = try await audioTrack.load(.formatDescriptions)
            } else {
                formatDescriptions = audioTrack.formatDescriptions
            }
            #elseif os(iOS)
            if #available(iOS 15.0, *) {
                formatDescriptions = try await audioTrack.load(.formatDescriptions)
            } else {
                formatDescriptions = audioTrack.formatDescriptions
            }
            #endif

            for description in formatDescriptions {
                let formatDesc = description as! CMFormatDescription
                if let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                    let sampleRate = Int(basicDesc.pointee.mSampleRate)
                    PluginLog.print("🔍 Audio sample rate: \(sampleRate) Hz")
                    return sampleRate
                }
            }

            return 0
        } catch {
            PluginLog.print("❌ Failed to detect audio sample rate: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Track Loading Helpers

    /// Loads video track from asset.
    static func loadVideoTrack(from asset: AVAsset) async throws -> AVAssetTrack {
        let tracks: [AVAssetTrack]
        #if os(macOS)
        if #available(macOS 13.0, *) {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } else {
            tracks = asset.tracks(withMediaType: .video)
        }
        #elseif os(iOS)
        if #available(iOS 15.0, *) {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } else {
            tracks = asset.tracks(withMediaType: .video)
        }
        #endif

        guard let track = tracks.first else {
            throw NSError(
                domain: "MediaInfoExtractor",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No video track found"]
            )
        }
        return track
    }

    /// Loads audio track from asset.
    static func loadAudioTrack(from asset: AVAsset) async throws -> AVAssetTrack? {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            return tracks.first
        } else {
            return asset.tracks(withMediaType: .audio).first
        }
        #elseif os(iOS)
        if #available(iOS 15.0, *) {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            return tracks.first
        } else {
            return asset.tracks(withMediaType: .audio).first
        }
        #endif
    }

    // MARK: - Video Format Detection

    /// Data class containing video format information for transcoding decisions.
    struct VideoFormatInfo {
        /// True if video uses HEVC/H.265 codec
        let isHevc: Bool

        /// Color bit depth (8 or 10)
        let bitDepth: Int

        /// True if video has HDR metadata (HLG, HDR10, etc.)
        let isHdr: Bool

        /// Codec profile string (e.g., "hvc1.2.4.H120")
        let profile: String?

        /// Determines if video requires transcoding to H.264 before applying GPU effects.
        ///
        /// HEVC 10-bit HDR videos have GPU surface compatibility issues
        /// when applying effects. These need to be transcoded to H.264 8-bit first.
        func needsTranscodingForEffects() -> Bool {
            // Transcode if: HEVC + (10-bit OR HDR)
            return isHevc && (bitDepth > 8 || isHdr)
        }
    }

    /// Extracts detailed video format information to determine transcoding needs.
    ///
    /// Specifically detects HEVC 10-bit HDR videos that cause issues
    /// when applying effects (colorMatrix, blur, overlay).
    ///
    /// - Parameter videoPath: Absolute path to video file
    /// - Returns: VideoFormatInfo with codec, bit depth, and HDR information
    static func getVideoFormatInfo(_ videoPath: String) async -> VideoFormatInfo {
        let url = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            PluginLog.print("❌ Video file does not exist: \(videoPath)")
            return VideoFormatInfo(isHevc: false, bitDepth: 8, isHdr: false, profile: nil)
        }

        let asset = AVURLAsset(url: url)

        do {
            let videoTrack = try await loadVideoTrack(from: asset)

            var isHevc = false
            var bitDepth = 8
            var isHdr = false
            var profile: String? = nil

            // Get format descriptions
            let formatDescriptions: [Any]
            #if os(macOS)
            if #available(macOS 13.0, *) {
                formatDescriptions = try await videoTrack.load(.formatDescriptions)
            } else {
                formatDescriptions = videoTrack.formatDescriptions
            }
            #elseif os(iOS)
            if #available(iOS 15.0, *) {
                formatDescriptions = try await videoTrack.load(.formatDescriptions)
            } else {
                formatDescriptions = videoTrack.formatDescriptions
            }
            #endif

            for description in formatDescriptions {
                let formatDesc = description as! CMFormatDescription
                let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)

                // Check if HEVC (kCMVideoCodecType_HEVC = 'hvc1')
                let hvc1 = fourCC("hvc1")
                let hev1 = fourCC("hev1")
                isHevc = (mediaSubType == hvc1 || mediaSubType == hev1)

                // Get extensions dictionary for detailed info
                if let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] {
                    // Check for bit depth
                    if let bitsPerComponent = extensions["BitsPerComponent"] as? Int {
                        bitDepth = bitsPerComponent
                    }

                    // Check for HDR transfer function
                    if let transferFunction = extensions[kCVImageBufferTransferFunctionKey as String] as? String {
                        // HDR transfer functions: HLG, PQ/HDR10, Linear
                        let hdrTransferFunctions = [
                            kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
                            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
                            kCVImageBufferTransferFunction_Linear as String,
                        ]
                        isHdr = hdrTransferFunctions.contains(transferFunction)
                    }

                    // Check color primaries for wide color gamut (BT.2020)
                    if let colorPrimaries = extensions[kCVImageBufferColorPrimariesKey as String] as? String {
                        if colorPrimaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String) {
                            isHdr = true
                        }
                    }

                    // Try to get codec profile
                    if let profileLevel = extensions["ProfileLevel"] as? String {
                        profile = profileLevel
                    }
                }

                // For HEVC without explicit bit depth, check if Main 10 profile
                if isHevc && bitDepth == 8 {
                    // Main 10 profile typically has profile indicator 2
                    if let profileStr = profile, profileStr.contains("Main 10") {
                        bitDepth = 10
                    }
                }
            }

            PluginLog.print(
                "🔍 Video format: path=\(videoPath), isHevc=\(isHevc), bitDepth=\(bitDepth), isHdr=\(isHdr), profile=\(profile ?? "unknown")"
            )

            return VideoFormatInfo(isHevc: isHevc, bitDepth: bitDepth, isHdr: isHdr, profile: profile)

        } catch {
            PluginLog.print("❌ Failed to get video format info for \(videoPath): \(error.localizedDescription)")
            return VideoFormatInfo(isHevc: false, bitDepth: 8, isHdr: false, profile: nil)
        }
    }

    /// Helper to create FourCC code from string
    private static func fourCC(_ string: String) -> FourCharCode {
        let chars = Array(string.utf8)
        guard chars.count == 4 else { return 0 }
        return FourCharCode(chars[0]) << 24 | FourCharCode(chars[1]) << 16 | FourCharCode(chars[2]) << 8 | FourCharCode(chars[3])
    }
}