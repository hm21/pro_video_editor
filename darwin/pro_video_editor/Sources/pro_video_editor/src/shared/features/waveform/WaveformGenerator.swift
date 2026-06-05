import AVFoundation
import Foundation

/// Service for generating waveform data from video/audio files using AVFoundation.
///
/// This class handles the waveform generation pipeline:
/// - Uses AVAssetReader to read audio samples
/// - Decodes audio to Linear PCM format
/// - Computes peak amplitudes per time block
/// - Supports stereo and mono audio
/// - Provides progress tracking during generation
/// - Supports cancellation of active jobs
///
/// Architecture:
/// - Uses AVAssetReader with AVAssetReaderTrackOutput for efficient reading
/// - Requests Linear PCM format for consistent processing
/// - Computes peaks in streaming fashion (constant memory usage)
/// - Returns normalized float arrays to Flutter
class WaveformGenerator {

    /// Generates waveform data from a video file asynchronously.
    ///
    /// - Parameters:
    ///   - config: Complete waveform configuration
    ///   - onProgress: Callback invoked with progress updates (0.0 to 1.0)
    ///   - onComplete: Callback invoked on success with waveform data dictionary
    ///   - onError: Callback invoked if generation fails
    /// - Returns: WaveformJobHandle for cancellation
    static func generate(
        config: WaveformConfig,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping ([String: Any?]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> WaveformJobHandle {

        var isCancelled = false

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Load source asset
                let sourceURL = URL(fileURLWithPath: config.inputPath)
                let asset = AVURLAsset(url: sourceURL)

                // Wait for tracks to be loaded
                let semaphore = DispatchSemaphore(value: 0)
                var loadError: Error?

                asset.loadValuesAsynchronously(forKeys: ["tracks", "duration", "playable"]) {
                    var error: NSError?
                    let tracksStatus = asset.statusOfValue(forKey: "tracks", error: &error)
                    let durationStatus = asset.statusOfValue(forKey: "duration", error: nil)

                    if tracksStatus == .failed {
                        loadError =
                            error
                            ?? NSError(
                                domain: "WaveformGenerator",
                                code: -10,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to load tracks"]
                            )
                    } else if durationStatus == .failed {
                        loadError = NSError(
                            domain: "WaveformGenerator",
                            code: -10,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to load duration"]
                        )
                    }
                    semaphore.signal()
                }

                semaphore.wait()

                if let error = loadError {
                    throw error
                }

                // Get audio track
                let audioTracks = asset.tracks(withMediaType: .audio)
                guard let audioTrack = audioTracks.first else {
                    throw NoAudioTrackException()
                }

                // Get audio properties
                let formatDescriptions =
                    audioTrack.formatDescriptions as! [CMAudioFormatDescription]
                guard let formatDesc = formatDescriptions.first else {
                    throw NSError(
                        domain: "WaveformGenerator",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No audio format description found"]
                    )
                }

                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)!.pointee
                let sampleRate = Int(asbd.mSampleRate)
                let channelCount = Int(asbd.mChannelsPerFrame)

                // Calculate duration
                let totalDurationSeconds = CMTimeGetSeconds(asset.duration)
                let totalDurationUs = Int64(totalDurationSeconds * 1_000_000)

                let startUs = config.startUs ?? 0
                let endUs = config.endUs ?? totalDurationUs
                let actualDurationUs = endUs - startUs
                let durationMs = Int(actualDurationUs / 1000)
                let actualDurationSeconds = Double(actualDurationUs) / 1_000_000

                // Calculate samples needed
                let totalSamples = max(
                    1, Int(actualDurationSeconds * Double(config.samplesPerSecond)))
                let samplesPerBlock = max(1, sampleRate / config.samplesPerSecond)

                // Configure output settings for Linear PCM
                let outputSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]

                // Create asset reader
                let reader = try AVAssetReader(asset: asset)

                // Apply time range if needed
                if startUs > 0 || endUs < totalDurationUs {
                    let startTime = CMTime(value: startUs, timescale: 1_000_000)
                    let endTime = CMTime(value: endUs, timescale: 1_000_000)
                    let duration = CMTimeSubtract(endTime, startTime)
                    reader.timeRange = CMTimeRange(start: startTime, duration: duration)
                }

                let trackOutput = AVAssetReaderTrackOutput(
                    track: audioTrack, outputSettings: outputSettings)
                trackOutput.alwaysCopiesSampleData = false
                reader.add(trackOutput)

                guard reader.startReading() else {
                    throw reader.error
                        ?? NSError(
                            domain: "WaveformGenerator",
                            code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"]
                        )
                }

                // Prepare output arrays
                var leftPeaks = [Float](repeating: 0, count: totalSamples)
                var rightPeaks: [Float]? =
                    channelCount >= 2 ? [Float](repeating: 0, count: totalSamples) : nil

                var currentSampleIndex = 0
                var accumulatedLeftPeak: Float = 0
                var accumulatedRightPeak: Float = 0
                var samplesInCurrentBlock = 0

                DispatchQueue.main.async { onProgress(0.0) }

                // Process audio samples
                while let sampleBuffer = trackOutput.copyNextSampleBuffer(), !isCancelled {
                    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                        continue
                    }

                    var length = 0
                    var dataPointer: UnsafeMutablePointer<Int8>?

                    CMBlockBufferGetDataPointer(
                        blockBuffer,
                        atOffset: 0,
                        lengthAtOffsetOut: nil,
                        totalLengthOut: &length,
                        dataPointerOut: &dataPointer
                    )

                    guard let data = dataPointer else { continue }

                    // Process 16-bit PCM samples
                    let sampleCount = length / (2 * channelCount)
                    let samples = data.withMemoryRebound(
                        to: Int16.self, capacity: sampleCount * channelCount
                    ) { ptr in
                        Array(UnsafeBufferPointer(start: ptr, count: sampleCount * channelCount))
                    }

                    var i = 0
                    while i < samples.count && currentSampleIndex < totalSamples {
                        // Read left channel
                        let leftSample = abs(Float(samples[i]) / Float(Int16.max))
                        accumulatedLeftPeak = max(accumulatedLeftPeak, leftSample)

                        // Read right channel if stereo
                        if channelCount >= 2 && i + 1 < samples.count {
                            let rightSample = abs(Float(samples[i + 1]) / Float(Int16.max))
                            accumulatedRightPeak = max(accumulatedRightPeak, rightSample)
                            i += channelCount
                        } else {
                            i += 1
                        }

                        samplesInCurrentBlock += 1

                        // Emit peak when block is complete
                        if samplesInCurrentBlock >= samplesPerBlock {
                            if currentSampleIndex < totalSamples {
                                leftPeaks[currentSampleIndex] = accumulatedLeftPeak
                                rightPeaks?[currentSampleIndex] = accumulatedRightPeak
                                currentSampleIndex += 1
                            }
                            accumulatedLeftPeak = 0
                            accumulatedRightPeak = 0
                            samplesInCurrentBlock = 0

                            // Update progress periodically
                            if currentSampleIndex % 100 == 0 {
                                let progress = Double(currentSampleIndex) / Double(totalSamples)
                                DispatchQueue.main.async {
                                    onProgress(min(1.0, max(0.0, progress)))
                                }
                            }
                        }
                    }
                }

                // Check cancellation
                if isCancelled {
                    reader.cancelReading()
                    throw NSError(
                        domain: "WaveformGenerator",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Waveform generation was cancelled"]
                    )
                }

                // Handle remaining samples
                if samplesInCurrentBlock > 0 && currentSampleIndex < totalSamples {
                    leftPeaks[currentSampleIndex] = accumulatedLeftPeak
                    rightPeaks?[currentSampleIndex] = accumulatedRightPeak
                    currentSampleIndex += 1
                }

                // Trim arrays to actual size if needed
                if currentSampleIndex < totalSamples {
                    leftPeaks = Array(leftPeaks.prefix(currentSampleIndex))
                    if rightPeaks != nil {
                        rightPeaks = Array(rightPeaks!.prefix(currentSampleIndex))
                    }
                }

                // Build result dictionary
                var result: [String: Any?] = [
                    "leftChannel": leftPeaks,
                    "sampleRate": sampleRate,
                    "duration": durationMs,
                    "samplesPerSecond": config.samplesPerSecond,
                ]

                if let rightPeaks = rightPeaks {
                    result["rightChannel"] = rightPeaks
                }

                DispatchQueue.main.async {
                    onProgress(1.0)
                    onComplete(result)
                }

            } catch {
                DispatchQueue.main.async {
                    onError(error)
                }
            }
        }

        return WaveformJobHandle {
            isCancelled = true
        }
    }

    /// Generates waveform data with streaming support.
    ///
    /// Unlike the regular generate method, this emits chunks progressively
    /// as they are generated, enabling real-time UI updates.
    ///
    /// - Parameters:
    ///   - config: Complete waveform configuration
    ///   - onChunk: Callback invoked for each chunk of waveform data
    ///   - onComplete: Callback invoked when generation is complete
    ///   - onError: Callback invoked if generation fails
    /// - Returns: WaveformJobHandle for cancellation
    static func generateStreaming(
        config: WaveformConfig,
        onChunk: @escaping ([String: Any?]) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) -> WaveformJobHandle {

        var isCancelled = false

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Load source asset
                let sourceURL = URL(fileURLWithPath: config.inputPath)
                let asset = AVURLAsset(url: sourceURL)

                // Wait for tracks to be loaded
                let semaphore = DispatchSemaphore(value: 0)
                var loadError: Error?

                asset.loadValuesAsynchronously(forKeys: ["tracks", "duration", "playable"]) {
                    var error: NSError?
                    let tracksStatus = asset.statusOfValue(forKey: "tracks", error: &error)
                    let durationStatus = asset.statusOfValue(forKey: "duration", error: nil)

                    if tracksStatus == .failed {
                        loadError =
                            error
                            ?? NSError(
                                domain: "WaveformGenerator",
                                code: -10,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to load tracks"]
                            )
                    } else if durationStatus == .failed {
                        loadError = NSError(
                            domain: "WaveformGenerator",
                            code: -10,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to load duration"]
                        )
                    }
                    semaphore.signal()
                }

                semaphore.wait()

                if let error = loadError {
                    throw error
                }

                // Get audio track
                let audioTracks = asset.tracks(withMediaType: .audio)
                guard let audioTrack = audioTracks.first else {
                    throw NoAudioTrackException()
                }

                // Get audio properties
                let formatDescriptions =
                    audioTrack.formatDescriptions as! [CMAudioFormatDescription]
                guard let formatDesc = formatDescriptions.first else {
                    throw NSError(
                        domain: "WaveformGenerator",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No audio format description found"]
                    )
                }

                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)!.pointee
                let sampleRate = Int(asbd.mSampleRate)
                let channelCount = Int(asbd.mChannelsPerFrame)

                // Calculate duration
                let totalDurationSeconds = CMTimeGetSeconds(asset.duration)
                let totalDurationUs = Int64(totalDurationSeconds * 1_000_000)

                let startUs = config.startUs ?? 0
                let endUs = config.endUs ?? totalDurationUs
                let actualDurationUs = endUs - startUs
                let durationMs = Int(actualDurationUs / 1000)
                let actualDurationSeconds = Double(actualDurationUs) / 1_000_000

                // Calculate samples needed
                let totalSamples = max(
                    1, Int(actualDurationSeconds * Double(config.samplesPerSecond)))
                let samplesPerBlock = max(1, sampleRate / config.samplesPerSecond)

                // Configure output settings for Linear PCM
                let outputSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]

                // Create asset reader
                let reader = try AVAssetReader(asset: asset)

                // Apply time range if needed
                if startUs > 0 || endUs < totalDurationUs {
                    let startTime = CMTime(value: startUs, timescale: 1_000_000)
                    let endTime = CMTime(value: endUs, timescale: 1_000_000)
                    let duration = CMTimeSubtract(endTime, startTime)
                    reader.timeRange = CMTimeRange(start: startTime, duration: duration)
                }

                let trackOutput = AVAssetReaderTrackOutput(
                    track: audioTrack, outputSettings: outputSettings)
                trackOutput.alwaysCopiesSampleData = false
                reader.add(trackOutput)

                guard reader.startReading() else {
                    throw reader.error
                        ?? NSError(
                            domain: "WaveformGenerator",
                            code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"]
                        )
                }

                // Prepare output arrays
                var leftPeaks = [Float](repeating: 0, count: totalSamples)
                var rightPeaks: [Float]? =
                    channelCount >= 2 ? [Float](repeating: 0, count: totalSamples) : nil

                var currentSampleIndex = 0
                var accumulatedLeftPeak: Float = 0
                var accumulatedRightPeak: Float = 0
                var samplesInCurrentBlock = 0
                var lastEmittedChunkEnd = 0

                // Process audio samples
                while let sampleBuffer = trackOutput.copyNextSampleBuffer(), !isCancelled {
                    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                        continue
                    }

                    var length = 0
                    var dataPointer: UnsafeMutablePointer<Int8>?

                    CMBlockBufferGetDataPointer(
                        blockBuffer,
                        atOffset: 0,
                        lengthAtOffsetOut: nil,
                        totalLengthOut: &length,
                        dataPointerOut: &dataPointer
                    )

                    guard let data = dataPointer else { continue }

                    // Process 16-bit PCM samples
                    let sampleCount = length / (2 * channelCount)
                    let samples = data.withMemoryRebound(
                        to: Int16.self, capacity: sampleCount * channelCount
                    ) { ptr in
                        Array(UnsafeBufferPointer(start: ptr, count: sampleCount * channelCount))
                    }

                    var i = 0
                    while i < samples.count && currentSampleIndex < totalSamples {
                        // Read left channel
                        let leftSample = abs(Float(samples[i]) / Float(Int16.max))
                        accumulatedLeftPeak = max(accumulatedLeftPeak, leftSample)

                        // Read right channel if stereo
                        if channelCount >= 2 && i + 1 < samples.count {
                            let rightSample = abs(Float(samples[i + 1]) / Float(Int16.max))
                            accumulatedRightPeak = max(accumulatedRightPeak, rightSample)
                            i += channelCount
                        } else {
                            i += 1
                        }

                        samplesInCurrentBlock += 1

                        // Emit peak when block is complete
                        if samplesInCurrentBlock >= samplesPerBlock {
                            if currentSampleIndex < totalSamples {
                                leftPeaks[currentSampleIndex] = accumulatedLeftPeak
                                rightPeaks?[currentSampleIndex] = accumulatedRightPeak
                                currentSampleIndex += 1

                                // Emit chunk when chunkSize is reached
                                if currentSampleIndex % config.chunkSize == 0
                                    || currentSampleIndex == totalSamples
                                {
                                    let chunkLeftPeaks = Array(
                                        leftPeaks[lastEmittedChunkEnd..<currentSampleIndex])
                                    let chunkRightPeaks = rightPeaks.map {
                                        Array($0[lastEmittedChunkEnd..<currentSampleIndex])
                                    }

                                    let progress = Double(currentSampleIndex) / Double(totalSamples)
                                    let chunk = buildChunkMap(
                                        id: config.id,
                                        leftPeaks: chunkLeftPeaks,
                                        rightPeaks: chunkRightPeaks,
                                        startIndex: lastEmittedChunkEnd,
                                        progress: min(1.0, max(0.0, progress)),
                                        sampleRate: sampleRate,
                                        totalDuration: durationMs,
                                        samplesPerSecond: config.samplesPerSecond,
                                        isComplete: false
                                    )

                                    DispatchQueue.main.async {
                                        onChunk(chunk)
                                    }

                                    lastEmittedChunkEnd = currentSampleIndex
                                }
                            }
                            accumulatedLeftPeak = 0
                            accumulatedRightPeak = 0
                            samplesInCurrentBlock = 0
                        }
                    }
                }

                // Check cancellation
                if isCancelled {
                    reader.cancelReading()
                    throw NSError(
                        domain: "WaveformGenerator",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Waveform generation was cancelled"]
                    )
                }

                // Handle remaining samples
                if samplesInCurrentBlock > 0 && currentSampleIndex < totalSamples {
                    leftPeaks[currentSampleIndex] = accumulatedLeftPeak
                    rightPeaks?[currentSampleIndex] = accumulatedRightPeak
                    currentSampleIndex += 1
                }

                // Emit final chunk with remaining samples
                if lastEmittedChunkEnd < currentSampleIndex {
                    let remainingLeftPeaks = Array(
                        leftPeaks[lastEmittedChunkEnd..<currentSampleIndex])
                    let remainingRightPeaks = rightPeaks.map {
                        Array($0[lastEmittedChunkEnd..<currentSampleIndex])
                    }

                    let finalChunk = buildChunkMap(
                        id: config.id,
                        leftPeaks: remainingLeftPeaks,
                        rightPeaks: remainingRightPeaks,
                        startIndex: lastEmittedChunkEnd,
                        progress: 1.0,
                        sampleRate: sampleRate,
                        totalDuration: durationMs,
                        samplesPerSecond: config.samplesPerSecond,
                        isComplete: true
                    )

                    DispatchQueue.main.async {
                        onChunk(finalChunk)
                    }
                } else {
                    // Just mark as complete
                    let completeChunk = buildChunkMap(
                        id: config.id,
                        leftPeaks: [],
                        rightPeaks: rightPeaks != nil ? [] : nil,
                        startIndex: currentSampleIndex,
                        progress: 1.0,
                        sampleRate: sampleRate,
                        totalDuration: durationMs,
                        samplesPerSecond: config.samplesPerSecond,
                        isComplete: true
                    )

                    DispatchQueue.main.async {
                        onChunk(completeChunk)
                    }
                }

                DispatchQueue.main.async {
                    onComplete()
                }

            } catch {
                DispatchQueue.main.async {
                    onError(error)
                }
            }
        }

        return WaveformJobHandle {
            isCancelled = true
        }
    }

    /// Builds a dictionary representing a waveform chunk for streaming.
    private static func buildChunkMap(
        id: String,
        leftPeaks: [Float],
        rightPeaks: [Float]?,
        startIndex: Int,
        progress: Double,
        sampleRate: Int,
        totalDuration: Int,
        samplesPerSecond: Int,
        isComplete: Bool
    ) -> [String: Any?] {
        var result: [String: Any?] = [
            "id": id,
            "leftChannel": leftPeaks,
            "startIndex": startIndex,
            "progress": progress,
            "sampleRate": sampleRate,
            "totalDuration": totalDuration,
            "samplesPerSecond": samplesPerSecond,
            "isComplete": isComplete,
        ]

        if let rightPeaks = rightPeaks {
            result["rightChannel"] = rightPeaks
        }

        return result
    }
}
