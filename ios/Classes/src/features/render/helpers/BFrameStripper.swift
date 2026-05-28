import AVFoundation
import CoreVideo
import Foundation

/// Re-encodes the H.264 video track of an MP4/MOV file so that the output
/// stream contains no B-frames (`AVVideoAllowFrameReorderingKey: false`).
///
/// `AVAssetExportSession`—the engine `RenderVideo` uses to materialise
/// the final file—does not expose any API to disable B-frame reordering.
/// The resulting stream therefore has `has_b_frames > 0`, which is
/// known to confuse `AVPlayerLooper`: when it duplicates the player item
/// for seamless looping, the preroll occasionally lands at a non-zero
/// `currentTime`, so the loop visually restarts at a random offset.
///
/// This helper takes the just-exported file and runs a second pass:
/// decoded video frames are re-encoded with frame reordering disabled,
/// audio (if any) is copied through unchanged. The original file is
/// then atomically replaced with the cleaned version.
///
/// Cost: roughly one decode + one encode of the final video at the same
/// resolution. For typical short clips (≤ 30 s, 1080p, ≤ 10 Mbps) this
/// adds about 10–20 % to the overall render time.
internal enum BFrameStripper {

    enum StripError: Error {
        case noVideoTrack
        case readerSetupFailed(String)
        case writerSetupFailed(String)
        case readFailed(String)
        case writeFailed(String)
    }

    /// Re-encodes the file at `url` in place, producing a B-frame-free
    /// H.264 stream. Throws if the operation fails — the caller should
    /// then fall back to the original file (which is left untouched
    /// until the new file has been written successfully).
    static func strip(
        at url: URL,
        shouldOptimizeForNetworkUse: Bool
    ) async throws {
        let asset = AVURLAsset(url: url)

        // Resolve video track.
        let videoTracks: [AVAssetTrack]
        if #available(iOS 15.0, *) {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } else {
            videoTracks = asset.tracks(withMediaType: .video)
        }
        guard let videoTrack = videoTracks.first else {
            throw StripError.noVideoTrack
        }

        // Resolve audio track (optional).
        let audioTracks: [AVAssetTrack]
        if #available(iOS 15.0, *) {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } else {
            audioTracks = asset.tracks(withMediaType: .audio)
        }
        let audioTrack = audioTracks.first

        // Resolve video track properties.
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let nominalFrameRate: Float
        let minFrameDuration: CMTime
        let estimatedDataRate: Float
        if #available(iOS 15.0, *) {
            naturalSize = try await videoTrack.load(.naturalSize)
            preferredTransform = try await videoTrack.load(.preferredTransform)
            nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            minFrameDuration = try await videoTrack.load(.minFrameDuration)
            estimatedDataRate = try await videoTrack.load(.estimatedDataRate)
        } else {
            naturalSize = videoTrack.naturalSize
            preferredTransform = videoTrack.preferredTransform
            nominalFrameRate = videoTrack.nominalFrameRate
            minFrameDuration = videoTrack.minFrameDuration
            estimatedDataRate = videoTrack.estimatedDataRate
        }

        let width = Int(abs(naturalSize.width))
        let height = Int(abs(naturalSize.height))
        guard width > 0, height > 0 else {
            throw StripError.noVideoTrack
        }

        // Pick a sensible GOP length. One keyframe per second is a good
        // trade-off between seek granularity and compression efficiency.
        let frameRate: Double = {
            if nominalFrameRate > 0 { return Double(nominalFrameRate) }
            if minFrameDuration.isValid, minFrameDuration.seconds > 0 {
                return 1.0 / minFrameDuration.seconds
            }
            return 30.0
        }()
        let keyframeInterval = max(1, Int(frameRate.rounded()))

        // Bitrate fallback: keep the source bitrate when known; otherwise
        // pick a generous default that won't visibly degrade the video.
        let bitrate: Int = {
            if estimatedDataRate > 0 { return Int(estimatedDataRate) }
            return max(2_000_000, width * height * 4)
        }()

        // --- Reader -------------------------------------------------
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw StripError.readerSetupFailed(error.localizedDescription)
        }

        let videoReaderOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        videoReaderOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoReaderOutput) else {
            throw StripError.readerSetupFailed("cannot add video output")
        }
        reader.add(videoReaderOutput)

        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioReaderOutput = output
            }
        }

        // --- Writer -------------------------------------------------
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                "bframe_strip_\(Int(Date().timeIntervalSince1970 * 1000))_"
                    + url.lastPathComponent)
        try? FileManager.default.removeItem(at: tempURL)

        let fileType: AVFileType = (url.pathExtension.lowercased() == "mov") ? .mov : .mp4
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: tempURL, fileType: fileType)
        } catch {
            throw StripError.writerSetupFailed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = shouldOptimizeForNetworkUse

        let compressionProperties: [String: Any] = [
            AVVideoAllowFrameReorderingKey: false,
            AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
        ]
        let videoWriterSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties,
        ]
        let videoWriterInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: videoWriterSettings)
        videoWriterInput.expectsMediaDataInRealTime = false
        videoWriterInput.transform = preferredTransform

        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        guard writer.canAdd(videoWriterInput) else {
            throw StripError.writerSetupFailed("cannot add video input")
        }
        writer.add(videoWriterInput)

        var audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            // Pass the audio packets through unchanged: outputSettings=nil
            // tells AVAssetWriterInput to write the source samples as-is.
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioWriterInput = input
            }
        }

        guard reader.startReading() else {
            throw StripError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.startWriting() else {
            throw StripError.writerSetupFailed(
                writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        // --- Pipe video frames --------------------------------------
        let videoQueue = DispatchQueue(label: "pro_video_editor.bframe_stripper.video")
        let audioQueue = DispatchQueue(label: "pro_video_editor.bframe_stripper.audio")
        let videoDone = DispatchSemaphore(value: 0)
        let audioDone = DispatchSemaphore(value: 0)

        var videoFailure: String?
        var audioFailure: String?

        videoWriterInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoWriterInput.isReadyForMoreMediaData {
                guard let sample = videoReaderOutput.copyNextSampleBuffer() else {
                    videoWriterInput.markAsFinished()
                    videoDone.signal()
                    return
                }
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                    continue
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if !pixelAdaptor.append(pixelBuffer, withPresentationTime: pts) {
                    videoFailure = writer.error?.localizedDescription ?? "append failed"
                    videoWriterInput.markAsFinished()
                    videoDone.signal()
                    return
                }
            }
        }

        if let audioWriterInput = audioWriterInput,
            let audioReaderOutput = audioReaderOutput
        {
            audioWriterInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioWriterInput.isReadyForMoreMediaData {
                    guard let sample = audioReaderOutput.copyNextSampleBuffer() else {
                        audioWriterInput.markAsFinished()
                        audioDone.signal()
                        return
                    }
                    if !audioWriterInput.append(sample) {
                        audioFailure = writer.error?.localizedDescription ?? "append failed"
                        audioWriterInput.markAsFinished()
                        audioDone.signal()
                        return
                    }
                }
            }
        } else {
            audioDone.signal()
        }

        // Wait for both inputs to drain off the main actor.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                videoDone.wait()
                audioDone.wait()
                continuation.resume()
            }
        }

        if let videoFailure = videoFailure {
            try? FileManager.default.removeItem(at: tempURL)
            throw StripError.writeFailed(videoFailure)
        }
        if let audioFailure = audioFailure {
            try? FileManager.default.removeItem(at: tempURL)
            throw StripError.writeFailed(audioFailure)
        }
        if reader.status == .failed {
            try? FileManager.default.removeItem(at: tempURL)
            throw StripError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status != .completed {
            try? FileManager.default.removeItem(at: tempURL)
            throw StripError.writeFailed(writer.error?.localizedDescription ?? "unknown")
        }

        // --- Atomic replace -----------------------------------------
        // Swap the freshly written temp file in for the original. Using
        // `replaceItemAt` preserves the destination's metadata while
        // making the swap effectively atomic on APFS.
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            // Fall back to a manual remove + move so we still end up with
            // the cleaned file at the original path.
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }
}
