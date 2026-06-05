import AVFoundation
import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// Exception thrown when no audio track is found in the video file.
class NoAudioTrackException: NSError, @unchecked Sendable {
    init() {
        super.init(
            domain: "ExtractAudio",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "No audio track found in video"]
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Service for extracting audio from video files using AVFoundation.
///
/// This class handles the audio extraction pipeline:
/// - Extracts audio track from video file
/// - Supports trimming (start/end time)
/// - Supports multiple output formats (M4A, AAC, CAF, WAV)
/// - Provides progress tracking during extraction
/// - Supports cancellation of active extraction jobs
class ExtractAudio {

    /// Extracts audio from a video file asynchronously.
    ///
    /// This method uses AVAssetExportSession for fast Passthrough export,
    /// or AVAssetReader + FileHandle for WAV transcoding.
    ///
    /// - Parameters:
    ///   - config: Complete extraction configuration
    ///   - onProgress: Callback invoked with progress updates (0.0 to 1.0)
    ///   - onComplete: Callback invoked on success with output bytes (nil if saved to file)
    ///   - onError: Callback invoked if extraction fails
    /// - Returns: Cancellation handle that can be used to stop the extraction
    static func extract(
        config: AudioExtractConfig,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (FlutterStandardTypedData?) -> Void,
        onError: @escaping (Error) -> Void
    ) -> AudioExtractJobHandle {

        // Check if WAV format is requested - requires transcoding
        let outputExtension = config.getOutputExtension().lowercased()
        if outputExtension == "wav" {
            return extractToWav(
                config: config,
                onProgress: onProgress,
                onComplete: onComplete,
                onError: onError
            )
        }

        // Use passthrough export for other formats
        return extractPassthrough(
            config: config,
            onProgress: onProgress,
            onComplete: onComplete,
            onError: onError
        )
    }

    /// Extracts audio using passthrough (no transcoding) for M4A, AAC, CAF formats.
    private static func extractPassthrough(
        config: AudioExtractConfig,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (FlutterStandardTypedData?) -> Void,
        onError: @escaping (Error) -> Void
    ) -> AudioExtractJobHandle {

        var exportSession: AVAssetExportSession?
        var progressTimer: Timer?
        var isCancelled = false

        // Execute extraction on background task
        let task = Task.detached(priority: .userInitiated) {
            do {
                // Load source video asset
                let sourceURL = URL(fileURLWithPath: config.inputPath)
                let asset = AVURLAsset(url: sourceURL)

                // Wait for tracks to be loaded
                try await asset.loadValues(forKeys: ["tracks", "duration"])

                let tracksStatus = asset.statusOfValue(forKey: "tracks", error: nil)
                let durationStatus = asset.statusOfValue(forKey: "duration", error: nil)

                if tracksStatus == .failed || durationStatus == .failed {
                    throw NSError(
                        domain: "ExtractAudio",
                        code: -10,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to load asset properties"]
                    )
                }

                // Determine output file location
                let outputURL: URL
                if let outputPath = config.outputPath {
                    outputURL = URL(fileURLWithPath: outputPath)
                } else {
                    let tempDir = FileManager.default.temporaryDirectory
                    let filename = "audio_\(Date().timeIntervalSince1970).\(config.getOutputExtension())"
                    outputURL = tempDir.appendingPathComponent(filename)
                }

                // Remove existing file if present
                try? FileManager.default.removeItem(at: outputURL)

                // Determine output file type based on extension
                let fileExtension = outputURL.pathExtension.lowercased()
                let outputFileType: AVFileType

                switch fileExtension {
                case "m4a":
                    outputFileType = .m4a
                case "aac":
                    outputFileType = .m4a
                case "caf":
                    outputFileType = .caf
                default:
                    outputFileType = .m4a
                }
                
                // Configure to export only audio tracks
                let audioTracks = asset.tracks(withMediaType: .audio)
                guard !audioTracks.isEmpty else {
                    throw NoAudioTrackException()
                }
                
                // Get the actual audio track to extract
                let audioTrack = audioTracks[0]
                
                // Determine the time range to extract
                let sourceTimeRange: CMTimeRange
                if let startUs = config.startUs, let endUs = config.endUs {
                    let startTime = CMTime(value: startUs, timescale: 1_000_000)
                    let endTime = CMTime(value: endUs, timescale: 1_000_000)
                    let duration = CMTimeSubtract(endTime, startTime)
                    sourceTimeRange = CMTimeRange(start: startTime, duration: duration)
                } else if let startUs = config.startUs {
                    let startTime = CMTime(value: startUs, timescale: 1_000_000)
                    let duration = CMTimeSubtract(asset.duration, startTime)
                    sourceTimeRange = CMTimeRange(start: startTime, duration: duration)
                } else if let endUs = config.endUs {
                    let endTime = CMTime(value: endUs, timescale: 1_000_000)
                    sourceTimeRange = CMTimeRange(start: .zero, duration: endTime)
                } else {
                    // Use the audio track's actual time range to capture all audio data
                    sourceTimeRange = audioTrack.timeRange
                }
                
                // Create composition to remap timestamps to start at zero
                let composition = AVMutableComposition()
                guard let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw NSError(
                        domain: "ExtractAudio",
                        code: -13,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create composition audio track"]
                    )
                }
                
                // Insert the audio track at time zero (remapping the timeline)
                try compositionAudioTrack.insertTimeRange(
                    sourceTimeRange,
                    of: audioTrack,
                    at: .zero
                )
                
                // Create export session with the composition (not the original asset)
                guard let session = AVAssetExportSession(
                    asset: composition,
                    presetName: AVAssetExportPresetPassthrough
                ) else {
                    throw NSError(
                        domain: "ExtractAudio",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"]
                    )
                }

                exportSession = session
                session.outputURL = outputURL
                session.outputFileType = outputFileType
                
                // Start progress tracking on main thread
                DispatchQueue.main.async {
                    onProgress(0.0)
                    
                    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                        guard !isCancelled else { return }
                        let progress = Double(session.progress)
                        onProgress(progress)
                    }
                }
                
                // Start export
                session.exportAsynchronously {
                    DispatchQueue.main.async {
                        progressTimer?.invalidate()
                        progressTimer = nil
                    }
                    
                    // Check cancellation
                    if isCancelled {
                        try? FileManager.default.removeItem(at: outputURL)
                        DispatchQueue.main.async {
                            onError(NSError(
                                domain: "ExtractAudio",
                                code: -3,
                                userInfo: [NSLocalizedDescriptionKey: "Extraction was cancelled"]
                            ))
                        }
                        return
                    }
                    
                    // Check export status - handle on background queue
                    DispatchQueue.global(qos: .userInitiated).async {
                        switch session.status {
                        case .completed:
                            do {
                                if config.outputPath != nil {
                                    // File output - return nil
                                    DispatchQueue.main.async {
                                        onProgress(1.0)
                                        onComplete(nil)
                                    }
                                } else {
                                    // Memory output - read file and return bytes (on background thread)
                                    let data = try Data(contentsOf: outputURL)
                                    let flutterData = FlutterStandardTypedData(bytes: data)
                                    
                                    // Clean up temporary file
                                    try? FileManager.default.removeItem(at: outputURL)
                                    
                                    DispatchQueue.main.async {
                                        onProgress(1.0)
                                        onComplete(flutterData)
                                    }
                                }
                            } catch {
                                try? FileManager.default.removeItem(at: outputURL)
                                DispatchQueue.main.async {
                                    onError(error)
                                }
                            }
                            
                        case .failed:
                            try? FileManager.default.removeItem(at: outputURL)
                            let error = session.error ?? NSError(
                                domain: "ExtractAudio",
                                code: -4,
                                userInfo: [NSLocalizedDescriptionKey: "Export failed with unknown error"]
                            )
                            DispatchQueue.main.async {
                                onError(error)
                            }
                            
                        case .cancelled:
                            try? FileManager.default.removeItem(at: outputURL)
                            DispatchQueue.main.async {
                                onError(NSError(
                                    domain: "ExtractAudio",
                                    code: -5,
                                    userInfo: [NSLocalizedDescriptionKey: "Export was cancelled"]
                                ))
                            }
                            
                        default:
                            try? FileManager.default.removeItem(at: outputURL)
                            DispatchQueue.main.async {
                                onError(NSError(
                                    domain: "ExtractAudio",
                                    code: -6,
                                    userInfo: [NSLocalizedDescriptionKey: "Export ended with unexpected status: \(session.status.rawValue)"]
                                ))
                            }
                        }
                    }
                }
                
            } catch {
                DispatchQueue.main.async {
                    progressTimer?.invalidate()
                    onError(error)
                }
            }
        }
        
        // Return cancellation handle
        return {
            isCancelled = true
            task.cancel()
            exportSession?.cancelExport()
            DispatchQueue.main.async {
                progressTimer?.invalidate()
            }
        }
    }
    
    /// Extracts audio to WAV format by streaming raw PCM into a RIFF/WAV file.
    private static func extractToWav(
        config: AudioExtractConfig,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (FlutterStandardTypedData?) -> Void,
        onError: @escaping (Error) -> Void
    ) -> AudioExtractJobHandle {

        /// Maximum PCM data allowed in a WAV file (~4 GB - 36 bytes).
        let maxWavDataSize: Int64 = 0xFFFF_FFFF - 36

        var assetReader: AVAssetReader?
        var isCancelled = false

        let task = Task.detached(priority: .userInitiated) {
            do {
                // Load source video asset
                let sourceURL = URL(fileURLWithPath: config.inputPath)
                let asset = AVURLAsset(url: sourceURL)

                // Wait for tracks to be loaded
                try await asset.loadValues(forKeys: ["tracks", "duration"])

                let tracksStatus = asset.statusOfValue(forKey: "tracks", error: nil)
                let durationStatus = asset.statusOfValue(forKey: "duration", error: nil)

                if tracksStatus == .failed || durationStatus == .failed {
                    throw NSError(
                        domain: "ExtractAudio",
                        code: -10,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to load asset properties"]
                    )
                }

                // Determine output file location
                let outputURL: URL
                if let outputPath = config.outputPath {
                    outputURL = URL(fileURLWithPath: outputPath)
                } else {
                    let tempDir = FileManager.default.temporaryDirectory
                    let filename = "audio_\(Date().timeIntervalSince1970).wav"
                    outputURL = tempDir.appendingPathComponent(filename)
                }

                // Remove existing file if present
                try? FileManager.default.removeItem(at: outputURL)

                // Get audio track
                let audioTracks = asset.tracks(withMediaType: .audio)
                guard let audioTrack = audioTracks.first else {
                    throw NoAudioTrackException()
                }

                // Get audio format (sample rate, channels)
                guard let formatDescription = (audioTrack.formatDescriptions as [AnyObject]).first
                        as! CMAudioFormatDescription? else {
                    throw NSError(
                        domain: "ExtractAudio",
                        code: -8,
                        userInfo: [NSLocalizedDescriptionKey: "No audio format description found"]
                    )
                }

                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)!.pointee
                let sampleRate = Int(asbd.mSampleRate)
                let channels = Int(asbd.mChannelsPerFrame)
                let bitsPerSample = 16

                // Calculate time range
                var timeRange: CMTimeRange
                if let startUs = config.startUs, let endUs = config.endUs {
                    let startTime = CMTime(value: startUs, timescale: 1_000_000)
                    let endTime = CMTime(value: endUs, timescale: 1_000_000)
                    timeRange = CMTimeRange(start: startTime, duration: CMTimeSubtract(endTime, startTime))
                } else if let startUs = config.startUs {
                    let startTime = CMTime(value: startUs, timescale: 1_000_000)
                    timeRange = CMTimeRange(start: startTime, duration: CMTimeSubtract(asset.duration, startTime))
                } else if let endUs = config.endUs {
                    let endTime = CMTime(value: endUs, timescale: 1_000_000)
                    timeRange = CMTimeRange(start: .zero, duration: endTime)
                } else {
                    // Use the audio track's actual time range to capture all audio data
                    timeRange = audioTrack.timeRange
                }

                // Create asset reader
                let reader = try AVAssetReader(asset: asset)
                assetReader = reader
                reader.timeRange = timeRange

                // Configure reader output for PCM
                let readerOutputSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: bitsPerSample,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]

                let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerOutputSettings)
                readerOutput.alwaysCopiesSampleData = false

                guard reader.canAdd(readerOutput) else {
                    throw NSError(
                        domain: "ExtractAudio",
                        code: -7,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot add reader output"]
                    )
                }
                reader.add(readerOutput)

                // Create output file and write a placeholder WAV header
                let fm = FileManager.default
                guard fm.createFile(atPath: outputURL.path, contents: nil) else {
                    throw NSError(
                        domain: "ExtractAudio",
                        code: -9,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot create output file at \(outputURL.path)"]
                    )
                }
                let fileHandle = try FileHandle(forWritingTo: outputURL)
                var writeSuccess = false
                defer {
                    try? fileHandle.close()
                    if !writeSuccess {
                        try? fm.removeItem(at: outputURL)
                    }
                }

                // Write placeholder header (data size = 0, will be patched later)
                fileHandle.write(buildWavHeader(
                    pcmDataSize: 0,
                    sampleRate: sampleRate,
                    channels: channels,
                    bitsPerSample: bitsPerSample
                ))

                guard reader.startReading() else {
                    throw reader.error ?? NSError(
                        domain: "ExtractAudio",
                        code: -10,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"]
                    )
                }

                DispatchQueue.main.async { onProgress(0.0) }

                let totalDuration = CMTimeGetSeconds(timeRange.duration)
                var totalPcmBytes: Int64 = 0

                // Stream PCM chunks directly to the file handle
                while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                    if isCancelled { break }

                    if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                        let length = CMBlockBufferGetDataLength(blockBuffer)

                        // Guard against WAV 4 GB size limit
                        totalPcmBytes += Int64(length)
                        if totalPcmBytes > maxWavDataSize {
                            reader.cancelReading()
                            throw NSError(
                                domain: "ExtractAudio",
                                code: -13,
                                userInfo: [NSLocalizedDescriptionKey:
                                    "WAV output exceeds maximum size (~4 GB). Consider splitting the audio into shorter segments."]
                            )
                        }

                        var chunk = Data(count: length)
                        _ = chunk.withUnsafeMutableBytes { ptr in
                            CMBlockBufferCopyDataBytes(
                                blockBuffer, atOffset: 0, dataLength: length,
                                destination: ptr.baseAddress!)
                        }
                        fileHandle.write(chunk)
                    }

                    // Update progress based on presentation timestamp
                    let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let elapsed = CMTimeGetSeconds(currentTime) - CMTimeGetSeconds(timeRange.start)
                    let progress = totalDuration > 0 ? min(max(elapsed / totalDuration, 0.0), 0.99) : 0.0
                    DispatchQueue.main.async { onProgress(progress) }
                }

                // Check if the reader failed (as opposed to naturally finishing)
                if reader.status == .failed {
                    throw reader.error ?? NSError(
                        domain: "ExtractAudio",
                        code: -11,
                        userInfo: [NSLocalizedDescriptionKey: "AVAssetReader failed during reading"]
                    )
                }

                if isCancelled {
                    reader.cancelReading()
                    DispatchQueue.main.async {
                        onError(NSError(
                            domain: "ExtractAudio",
                            code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "Extraction was cancelled"]
                        ))
                    }
                    return
                }

                // Seek back to the start and patch the WAV header with the real data size
                fileHandle.seek(toFileOffset: 0)
                fileHandle.write(buildWavHeader(
                    pcmDataSize: Int(totalPcmBytes),
                    sampleRate: sampleRate,
                    channels: channels,
                    bitsPerSample: bitsPerSample
                ))

                writeSuccess = true

                if config.outputPath != nil {
                    // File output — return nil data
                    DispatchQueue.main.async {
                        onProgress(1.0)
                        onComplete(nil)
                    }
                } else {
                    // Memory output — read file back and clean up
                    let data = try Data(contentsOf: outputURL)
                    let flutterData = FlutterStandardTypedData(bytes: data)
                    try? fm.removeItem(at: outputURL)
                    DispatchQueue.main.async {
                        onProgress(1.0)
                        onComplete(flutterData)
                    }
                }

            } catch {
                DispatchQueue.main.async {
                    onError(error)
                }
            }
        }

        // Return cancellation handle
        return {
            isCancelled = true
            task.cancel()
            assetReader?.cancelReading()
        }
    }

    /// Builds a standard 44-byte RIFF/WAV header for 16-bit PCM audio.
    private static func buildWavHeader(
        pcmDataSize: Int,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> Data {
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var header = Data()
        header.append(contentsOf: [UInt8]("RIFF".utf8))
        header.append(UInt32(36 + pcmDataSize).littleEndianBytes)
        header.append(contentsOf: [UInt8]("WAVE".utf8))
        header.append(contentsOf: [UInt8]("fmt ".utf8))
        header.append(UInt32(16).littleEndianBytes) // PCM sub-chunk size
        header.append(UInt16(1).littleEndianBytes) // AudioFormat = PCM
        header.append(UInt16(channels).littleEndianBytes)
        header.append(UInt32(sampleRate).littleEndianBytes)
        header.append(UInt32(byteRate).littleEndianBytes)
        header.append(UInt16(blockAlign).littleEndianBytes)
        header.append(UInt16(bitsPerSample).littleEndianBytes)
        header.append(contentsOf: [UInt8]("data".utf8))
        header.append(UInt32(pcmDataSize).littleEndianBytes)
        return header
    }
}

private extension UInt32 {
    var littleEndianBytes: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}

private extension UInt16 {
    var littleEndianBytes: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}