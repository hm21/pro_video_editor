import AVFoundation
import Foundation

/// Pre-renders a reversed audio segment into a PCM WAV temp file.
///
/// Unlike the frame-slice approach used by the old `reverseTimeRanges`
/// implementation (which reverses ~30 chunk positions per second but plays
/// each chunk forward, causing ~30 audible artefacts per second), this
/// class decodes the audio to raw PCM, reverses every sample in-place,
/// and writes the result as a WAV file.  The caller inserts the WAV into
/// the composition with a single `insertTimeRange` call — no clicks, no
/// gaps, and the audio sounds exactly like the video played backwards.
internal enum AudioReverser {

    /// Result of a successful reversal.
    struct Result {
        /// Temporary PCM WAV file.  The caller MUST delete this once
        /// the AVAssetExportSession has finished.
        let outputURL: URL
        /// Duration of the reversed audio.
        let duration: CMTime
    }

    // MARK: - Public API

    /// Decodes [startTime, endTime) from `inputPath`, reverses the PCM
    /// samples on the frame level (stereo 16-bit, 44.1 kHz), and writes
    /// the result to a temporary WAV file.
    ///
    /// Returns `nil` on failure (no audio track, empty PCM, write error)
    /// so the caller can fall back gracefully to no audio rather than
    /// failing the whole render.
    static func reverse(
        inputPath: String,
        startTime: CMTime,
        endTime: CMTime
    ) async -> Result? {
        let sourceURL = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            PluginLog.print("⚠️ AudioReverser: source file not found: \(inputPath)")
            return nil
        }

        let asset = AVURLAsset(url: sourceURL)

        // Resolve actual asset duration for the "until end" case.
        let assetDuration: CMTime
        #if os(macOS)
        if #available(macOS 13.0, *) {
            assetDuration = (try? await asset.load(.duration)) ?? .zero
        } else {
            assetDuration = asset.duration
        }
        #elseif os(iOS)
        if #available(iOS 15.0, *) {
            assetDuration = (try? await asset.load(.duration)) ?? .zero
        } else {
            assetDuration = asset.duration
        }
        #endif

        let effectiveStart = CMTimeMaximum(startTime, .zero)
        let effectiveEnd   = CMTimeMinimum(endTime, assetDuration)
        let segmentDuration = CMTimeSubtract(effectiveEnd, effectiveStart)
        guard CMTimeCompare(segmentDuration, .zero) > 0 else {
            PluginLog.print("⚠️ AudioReverser: invalid segment \(effectiveStart.seconds)s–\(effectiveEnd.seconds)s")
            return nil
        }

        // Load audio track.
        let audioTracks: [AVAssetTrack]
        do {
            #if os(macOS)
            if #available(macOS 13.0, *) {
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } else {
                audioTracks = asset.tracks(withMediaType: .audio)
            }
            #elseif os(iOS)
            if #available(iOS 15.0, *) {
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } else {
                audioTracks = asset.tracks(withMediaType: .audio)
            }
            #endif
        } catch {
            PluginLog.print("⚠️ AudioReverser: failed to load tracks: \(error)")
            return nil
        }
        guard let audioTrack = audioTracks.first else {
            PluginLog.print("⚠️ AudioReverser: no audio track in \(inputPath)")
            return nil
        }

        // Fixed decode format: 44.1 kHz stereo 16-bit LE PCM.
        let sampleRate: Double  = 44100
        let channelCount: Int   = 2
        let bitsPerSample: Int  = 16
        let bytesPerFrame       = channelCount * (bitsPerSample / 8) // = 4

        let outputSettings: [String: Any] = [
            AVFormatIDKey:                  kAudioFormatLinearPCM,
            AVSampleRateKey:                sampleRate,
            AVNumberOfChannelsKey:          channelCount,
            AVLinearPCMBitDepthKey:         bitsPerSample,
            AVLinearPCMIsFloatKey:          false,
            AVLinearPCMIsBigEndianKey:      false,
            AVLinearPCMIsNonInterleaved:    false,
        ]

        // Decode PCM.
        let pcm: Data
        do {
            pcm = try await readPcm(
                from: asset,
                track: audioTrack,
                start: effectiveStart,
                duration: segmentDuration,
                outputSettings: outputSettings
            )
        } catch {
            PluginLog.print("⚠️ AudioReverser: PCM decode failed: \(error)")
            return nil
        }
        guard !pcm.isEmpty else {
            PluginLog.print("⚠️ AudioReverser: decoded PCM is empty")
            return nil
        }

        // Reverse PCM on the frame level (swap frame 0 ↔ last, etc.).
        var bytes = [UInt8](pcm)
        let frameCount = bytes.count / bytesPerFrame
        var lo = 0
        var hi = frameCount - 1
        while lo < hi {
            let loOff = lo * bytesPerFrame
            let hiOff = hi * bytesPerFrame
            for i in 0..<bytesPerFrame {
                bytes.swapAt(loOff + i, hiOff + i)
            }
            lo += 1
            hi -= 1
        }

        // Write WAV file.
        let outputURL = makeTemporaryWavURL()
        do {
            let wavData = makeWav(
                pcmBytes: Data(bytes),
                sampleRate:   Int(sampleRate),
                channelCount: channelCount,
                bitsPerSample: bitsPerSample
            )
            try wavData.write(to: outputURL, options: .atomic)
        } catch {
            PluginLog.print("⚠️ AudioReverser: WAV write failed: \(error)")
            return nil
        }

        let outputFrameCount = bytes.count / bytesPerFrame
        let duration = CMTime(
            value: CMTimeValue(outputFrameCount),
            timescale: CMTimeScale(sampleRate)
        )

        PluginLog.print(
            "⏪ AudioReverser: reversed \(bytes.count) bytes (\(duration.seconds)s) for \(inputPath)"
        )
        return Result(outputURL: outputURL, duration: duration)
    }

    // MARK: - Private helpers

    private static func readPcm(
        from asset: AVAsset,
        track: AVAssetTrack,
        start: CMTime,
        duration: CMTime,
        outputSettings: [String: Any]
    ) async throws -> Data {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: start, duration: duration)

        let trackOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings
        )
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw NSError(
                domain: "AudioReverser",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add track output to reader"]
            )
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "AudioReverser",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetReader.startReading failed"]
            )
        }

        var pcm = Data()
        while reader.status == .reading,
              let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                if length > 0 {
                    var tempBytes = [UInt8](repeating: 0, count: length)
                    let status = CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: length,
                        destination: &tempBytes
                    )
                    if status == kCMBlockBufferNoErr {
                        pcm.append(contentsOf: tempBytes)
                    }
                }
            }
        }
        if reader.status == .failed, let err = reader.error { throw err }
        return pcm
    }

    private static func makeTemporaryWavURL() -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let name = "reverse_audio_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString).wav"
        return tmp.appendingPathComponent(name)
    }

    private static func makeWav(
        pcmBytes: Data,
        sampleRate: Int,
        channelCount: Int,
        bitsPerSample: Int
    ) -> Data {
        let byteRate   = sampleRate * channelCount * bitsPerSample / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let dataSize   = UInt32(pcmBytes.count)
        let chunkSize  = UInt32(36) + dataSize

        var header = Data(capacity: 44)
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.appendLE(UInt32(chunkSize))
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.appendLE(UInt32(16))
        header.appendLE(UInt16(1))                           // PCM
        header.appendLE(UInt16(channelCount))
        header.appendLE(UInt32(sampleRate))
        header.appendLE(UInt32(byteRate))
        header.appendLE(UInt16(blockAlign))
        header.appendLE(UInt16(bitsPerSample))
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.appendLE(dataSize)

        var out = Data(capacity: header.count + pcmBytes.count)
        out.append(header)
        out.append(pcmBytes)
        return out
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}