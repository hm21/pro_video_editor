import AVFoundation
import Foundation
import FlutterMacOS

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
    /// or AVAssetReader/AVAssetWriter for WAV transcoding.
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
        
        // Execute extraction on background queue
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Load source video asset
                let sourceURL = URL(fileURLWithPath: config.inputPath)
                let asset = AVURLAsset(url: sourceURL)
                
                // Wait for tracks to be loaded
                let loadSemaphore = DispatchSemaphore(value: 0)
                var loadError: Error?
                
                asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
                    let tracksStatus = asset.statusOfValue(forKey: "tracks", error: nil)
                    let durationStatus = asset.statusOfValue(forKey: "duration", error: nil)
                    
                    if tracksStatus == .failed || durationStatus == .failed {
                        loadError = NSError(
                            domain: "ExtractAudio",
                            code: -10,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to load asset properties"]
                        )
                    }
                    loadSemaphore.signal()
                }
                
                loadSemaphore.wait()
                
                if let error = loadError {
                    throw error
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
                
                // Create export session with audio-only preset
                guard let session = AVAssetExportSession(
                    asset: asset,
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
                
                // Configure to export only audio tracks
                let audioTracks = asset.tracks(withMediaType: .audio)
                guard !audioTracks.isEmpty else {
                    throw NoAudioTrackException()
                }
                
                // Apply time range if trimming is requested
                if let startUs = config.startUs, let endUs = config.endUs {
                    let startTime = CMTime(value: startUs, timescale: 1_000_000)
                    let endTime = CMTime(value: endUs, timescale: 1_000_000)
                    let duration = CMTimeSubtract(endTime, startTime)
                    session.timeRange = CMTimeRange(start: startTime, duration: duration)
                } else if let startUs = config.startUs {
                    let startTime = CMTime(value: startUs, timescale: 1_000_000)
                    let duration = CMTimeSubtract(asset.duration, startTime)
                    session.timeRange = CMTimeRange(start: startTime, duration: duration)
                } else if let endUs = config.endUs {
                    let endTime = CMTime(value: endUs, timescale: 1_000_000)
                    session.timeRange = CMTimeRange(start: .zero, duration: endTime)
                }
                
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
            exportSession?.cancelExport()
            DispatchQueue.main.async {
                progressTimer?.invalidate()
            }
        }
    }
    
    /// Extracts audio to WAV format using AVAssetReader/AVAssetWriter for PCM transcoding.
    private static func extractToWav(
        config: AudioExtractConfig,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (FlutterStandardTypedData?) -> Void,
        onError: @escaping (Error) -> Void
    ) -> AudioExtractJobHandle {
        
        var assetReader: AVAssetReader?
        var assetWriter: AVAssetWriter?
        var isCancelled = false
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Load source video asset
                let sourceURL = URL(fileURLWithPath: config.inputPath)
                let asset = AVURLAsset(url: sourceURL)
                
                // Wait for tracks to be loaded
                let loadSemaphore = DispatchSemaphore(value: 0)
                var loadError: Error?
                
                asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
                    let tracksStatus = asset.statusOfValue(forKey: "tracks", error: nil)
                    let durationStatus = asset.statusOfValue(forKey: "duration", error: nil)
                    
                    if tracksStatus == .failed || durationStatus == .failed {
                        loadError = NSError(
                            domain: "ExtractAudio",
                            code: -10,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to load asset properties"]
                        )
                    }
                    loadSemaphore.signal()
                }
                
                loadSemaphore.wait()
                
                if let error = loadError {
                    throw error
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
                
                // Calculate time range
                var timeRange = CMTimeRange(start: .zero, duration: asset.duration)
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
                }
                
                // Create asset reader
                let reader = try AVAssetReader(asset: asset)
                assetReader = reader
                reader.timeRange = timeRange
                
                // Configure reader output for PCM
                let readerOutputSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
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
                
                // Create asset writer
                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
                assetWriter = writer
                
                // Get audio format description for writer input
                let formatDescriptions = audioTrack.formatDescriptions as! [CMFormatDescription]
                guard let formatDescription = formatDescriptions.first else {
                    throw NSError(
                        domain: "ExtractAudio",
                        code: -8,
                        userInfo: [NSLocalizedDescriptionKey: "No audio format description found"]
                    )
                }
                
                let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
                let sampleRate = audioStreamBasicDescription?.mSampleRate ?? 44100
                let channels = audioStreamBasicDescription?.mChannelsPerFrame ?? 2
                
                // Create audio channel layout based on number of channels
                var channelLayout = AudioChannelLayout()
                channelLayout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
                channelLayout.mNumberChannelDescriptions = 0
                channelLayout.mChannelLayoutTag = switch channels {
                    case 1: kAudioChannelLayoutTag_Mono
                    case 2: kAudioChannelLayoutTag_Stereo
                    case 3: kAudioChannelLayoutTag_MPEG_3_0_A
                    case 4: kAudioChannelLayoutTag_Quadraphonic
                    case 5: kAudioChannelLayoutTag_MPEG_5_0_A
                    case 6: kAudioChannelLayoutTag_MPEG_5_1_A
                    case 7: kAudioChannelLayoutTag_MPEG_6_1_A
                    case 8: kAudioChannelLayoutTag_MPEG_7_1_A
                    default: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
                }

                // Configure writer input for PCM WAV
                let writerInputSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                    AVChannelLayoutKey: Data(bytes: &channelLayout, count: MemoryLayout<AudioChannelLayout>.size)
                ]
                
                let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerInputSettings)
                writerInput.expectsMediaDataInRealTime = false
                
                guard writer.canAdd(writerInput) else {
                    throw NSError(
                        domain: "ExtractAudio",
                        code: -9,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot add writer input"]
                    )
                }
                writer.add(writerInput)
                
                // Start reading and writing
                guard reader.startReading() else {
                    throw reader.error ?? NSError(
                        domain: "ExtractAudio",
                        code: -10,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"]
                    )
                }
                
                guard writer.startWriting() else {
                    throw writer.error ?? NSError(
                        domain: "ExtractAudio",
                        code: -11,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"]
                    )
                }
                
                writer.startSession(atSourceTime: timeRange.start)
                
                // Calculate total duration for progress
                let totalDuration = CMTimeGetSeconds(timeRange.duration)
                
                DispatchQueue.main.async {
                    onProgress(0.0)
                }
                
                // Process samples
                let processingQueue = DispatchQueue(label: "com.provideo.wav.processing")
                let semaphore = DispatchSemaphore(value: 0)
                var processingError: Error?
                
                writerInput.requestMediaDataWhenReady(on: processingQueue) {
                    while writerInput.isReadyForMoreMediaData && !isCancelled {
                        if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                            // Update progress
                            let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                            let elapsed = CMTimeGetSeconds(currentTime) - CMTimeGetSeconds(timeRange.start)
                            let progress = min(max(elapsed / totalDuration, 0.0), 1.0)
                            DispatchQueue.main.async {
                                onProgress(progress)
                            }
                            
                            if !writerInput.append(sampleBuffer) {
                                processingError = writer.error
                                break
                            }
                        } else {
                            // No more samples
                            writerInput.markAsFinished()
                            break
                        }
                    }
                    
                    if isCancelled {
                        reader.cancelReading()
                        writer.cancelWriting()
                    }
                    
                    semaphore.signal()
                }
                
                // Wait for processing to complete
                semaphore.wait()
                
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
                
                if let error = processingError {
                    try? FileManager.default.removeItem(at: outputURL)
                    DispatchQueue.main.async {
                        onError(error)
                    }
                    return
                }
                
                // Finish writing
                let finishSemaphore = DispatchSemaphore(value: 0)
                writer.finishWriting {
                    finishSemaphore.signal()
                }
                finishSemaphore.wait()
                
                if writer.status == .completed {
                    if config.outputPath != nil {
                        DispatchQueue.main.async {
                            onProgress(1.0)
                            onComplete(nil)
                        }
                    } else {
                        let data = try Data(contentsOf: outputURL)
                        let flutterData = FlutterStandardTypedData(bytes: data)
                        try? FileManager.default.removeItem(at: outputURL)
                        DispatchQueue.main.async {
                            onProgress(1.0)
                            onComplete(flutterData)
                        }
                    }
                } else {
                    try? FileManager.default.removeItem(at: outputURL)
                    let error = writer.error ?? NSError(
                        domain: "ExtractAudio",
                        code: -12,
                        userInfo: [NSLocalizedDescriptionKey: "WAV export failed"]
                    )
                    DispatchQueue.main.async {
                        onError(error)
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
            assetReader?.cancelReading()
            assetWriter?.cancelWriting()
        }
    }
}
