import Foundation

/// A single trimmed audio window that participates in an audio merge.
struct AudioMergeSegmentConfig {
  /// Absolute file path to the source video/audio for this segment.
  let inputPath: String

  /// Window start in the source timeline, in microseconds.
  let startUs: Int64

  /// Window end in the source timeline, in microseconds (`> startUs`).
  let endUs: Int64

  /// Playback speed multiplier applied after trimming (`> 0`, pitch preserved).
  let speed: Double

  /// The played length this segment contributes to the output, in microseconds
  /// (`(endUs - startUs) / speed`).
  var outputDurationUs: Double {
    Double(endUs - startUs) / speed
  }
}

/// Configuration model for merging several trimmed audio windows into one file.
///
/// Mirrors `AudioExtractConfig` but carries an ordered list of segments plus an
/// optional uniform output sample rate / channel count.
struct AudioMergeConfig {
  /// Unique task identifier for progress tracking and cancellation.
  let id: String

  /// Desired output format (`wav`, `aac`, `m4a`, `caf`, ...).
  let format: String

  /// Optional uniform output sample rate in Hz. `nil` = derive from the first
  /// audio-bearing segment.
  let sampleRate: Int?

  /// Optional uniform output channel count. `nil` = derive from the first
  /// audio-bearing segment.
  let channels: Int?

  /// Absolute path where the merged file is written.
  let outputPath: String

  /// Ordered segments to concatenate.
  let segments: [AudioMergeSegmentConfig]

  /// Whether the caller pinned an explicit uniform output format.
  var hasExplicitFormat: Bool { sampleRate != nil || channels != nil }

  /// Builds an `AudioMergeConfig` from Flutter method-call arguments.
  ///
  /// Returns `nil` if a required field is missing or a segment is invalid
  /// (`endUs <= startUs`, `speed <= 0`, empty list).
  static func fromArguments(_ arguments: [String: Any]?) -> AudioMergeConfig? {
    guard let args = arguments,
      let id = args["id"] as? String,
      let format = args["format"] as? String,
      let outputPath = args["outputPath"] as? String,
      let rawSegments = args["segments"] as? [[String: Any]],
      !rawSegments.isEmpty
    else {
      return nil
    }

    var segments: [AudioMergeSegmentConfig] = []
    for raw in rawSegments {
      guard let inputPath = raw["inputPath"] as? String,
        let startUs = (raw["startTime"] as? NSNumber)?.int64Value,
        let endUs = (raw["endTime"] as? NSNumber)?.int64Value
      else {
        return nil
      }
      let speed = (raw["speed"] as? NSNumber)?.doubleValue ?? 1.0
      if endUs <= startUs || speed <= 0 {
        return nil
      }
      segments.append(
        AudioMergeSegmentConfig(
          inputPath: inputPath, startUs: startUs, endUs: endUs, speed: speed))
    }

    let sampleRate = (args["sampleRate"] as? NSNumber)?.intValue
    let channels = (args["channels"] as? NSNumber)?.intValue

    return AudioMergeConfig(
      id: id,
      format: format,
      sampleRate: sampleRate,
      channels: channels,
      outputPath: outputPath,
      segments: segments)
  }

  /// Returns the output file extension for the configured format.
  func getOutputExtension() -> String {
    switch format.lowercased() {
    case "mp3": return "mp3"
    case "aac": return "m4a"
    case "m4a": return "m4a"
    case "caf": return "caf"
    case "wav": return "wav"
    default: return "m4a"
    }
  }

  /// Builds the equivalent single-clip `AudioExtractConfig` for a segment.
  ///
  /// Used for the single-segment fast path, which delegates to `ExtractAudio`
  /// to guarantee byte-for-byte parity with `extractAudioToFile`.
  func extractConfig(for segment: AudioMergeSegmentConfig) -> AudioExtractConfig {
    AudioExtractConfig(
      id: id,
      inputPath: segment.inputPath,
      fileExtension: "",
      format: format,
      startUs: segment.startUs,
      endUs: segment.endUs,
      speed: segment.speed,
      outputPath: outputPath)
  }
}
