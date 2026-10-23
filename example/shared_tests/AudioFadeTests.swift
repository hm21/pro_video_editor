import AVFoundation
import Foundation
import XCTest

@testable import pro_video_editor

// Compiled into *both* the iOS and the macOS RunnerTests target (referenced
// from each project as ../shared_tests/…), like TrimmedPreTranscodeTests.swift:
// the audio pre-render is shared Darwin code.

// MARK: - Custom audio track fade

/// The fade `AudioPreRenderer` bakes into a custom audio track: a linear ramp
/// from and to silence at the edges of the audio, the same envelope the
/// Android pre-render writes.
final class AudioFadeTests: XCTestCase {
  /// 16-bit stereo, i.e. one frame is four bytes.
  private let bytesPerFrame = 4
  /// The level the tests start from; a quarter step is exact.
  private let level: Int16 = 10_000

  func testAFadeInRisesLinearlyFromSilence() {
    let samples = fadedBody(frames: 8, fadeInFrames: 4, fadeOutFrames: 0)

    XCTAssertEqual(Array(samples.prefix(5)), [0, 2500, 5000, 7500, 10_000])
    XCTAssertEqual(Array(samples.suffix(3)), [level, level, level])
  }

  /// The last audible frame is one step above silence, never louder.
  func testAFadeOutFallsLinearlyToTheEndOfTheAudio() {
    let samples = fadedBody(frames: 8, fadeInFrames: 0, fadeOutFrames: 4)

    XCTAssertEqual(Array(samples.prefix(4)), [level, level, level, level])
    XCTAssertEqual(Array(samples.suffix(4)), [10_000, 7500, 5000, 2500])
  }

  /// Two fades longer than the audio between them meet in the middle, and the
  /// quieter ramp wins rather than the fade in jumping to full volume.
  func testOverlappingFadesKeepTheQuieterRamp() {
    XCTAssertEqual(fadedBody(frames: 4, fadeInFrames: 4, fadeOutFrames: 4), [0, 2500, 5000, 2500])
  }

  func testAFadeScalesNegativeSamples() {
    XCTAssertEqual(
      fadedBody(frames: 4, fadeInFrames: 2, fadeOutFrames: 0, level: -10_000),
      [0, -5000, -10_000, -10_000])
  }

  /// A track that plays once and then goes silent fades out where its audio
  /// ends; the silence padding after it stays silent and untouched.
  func testAFadeOutEndsWhereTheAudibleBytesEnd() {
    var pcm = levelFrames(4, level: level) + Data(count: 4 * bytesPerFrame)
    AudioPreRenderer.applyFade(
      to: &pcm,
      audibleBytes: 4 * bytesPerFrame,
      bytesPerFrame: bytesPerFrame,
      fadeInFrames: 0,
      fadeOutFrames: 2
    )

    XCTAssertEqual(leftSamples(pcm), [level, level, 10_000, 5000, 0, 0, 0, 0])
  }

  func testNoFadeLeavesTheAudioUntouched() {
    let original = levelFrames(4, level: level)
    var pcm = original
    AudioPreRenderer.applyFade(
      to: &pcm,
      audibleBytes: pcm.count,
      bytesPerFrame: bytesPerFrame,
      fadeInFrames: 0,
      fadeOutFrames: 0
    )

    XCTAssertEqual(pcm, original)
  }

  // MARK: - Volume curve

  /// A volume curve scales each frame by the curve at the frame's place on
  /// the output timeline, `outputStart + frame / sampleRate`, and leaves the
  /// silence after the audible bytes and the frames at 1 untouched.
  func testAVolumeCurveScalesFramesAtTheirTime() {
    // One frame per millisecond; the audio starts 1 ms into the output, and
    // the curve goes down to half from 2 to 4 ms and back up from 6 to 8 ms.
    let curve = VolumeCurve.from([2000, 1, 4000, 0.5, 6000, 0.5, 8000, 1] as [NSNumber])!
    var pcm = levelFrames(8, level: level) + Data(count: 2 * bytesPerFrame)
    AudioPreRenderer.applyVolumeCurve(
      to: &pcm,
      audibleBytes: 8 * bytesPerFrame,
      bytesPerFrame: bytesPerFrame,
      sampleRate: 1000,
      startUs: 1000,
      curve: curve
    )

    XCTAssertEqual(
      leftSamples(pcm), [level, level, 7500, 5000, 5000, 5000, 7500, level, 0, 0])
    XCTAssertEqual(leftSamples(pcm), rightSamples(pcm), "both channels share one gain")
  }

  /// The curve arrives as interleaved microseconds and volumes; only the
  /// stretches below 1 are worth rewriting.
  func testAVolumeCurveKnowsWhereItLowersTheVolume() {
    let curve = VolumeCurve.from([0, 1, 1000, 0.25, 2000, 1, 5000, 1, 6000, 0.5] as [NSNumber])!
    XCTAssertEqual(curve.volume(atUs: 500), 0.625, accuracy: 1e-9)
    XCTAssertEqual(curve.volume(atUs: 9000), 0.5, accuracy: 1e-9)
    XCTAssertEqual(curve.loweredRangesUs(), [0...2000, 5000...Int64.max])
    XCTAssertNil(VolumeCurve.from([1] as [NSNumber]))
  }

  /// A volume that is not a number leaves the audio as it is, and a time that
  /// does not fit in microseconds drops its point instead of trapping.
  func testAVolumeCurveSurvivesValuesThatAreNotNumbers() {
    let curve = VolumeCurve.from(
      [0, Double.nan, Double.infinity, 0.2, 1000, 0.5] as [NSNumber])!
    XCTAssertEqual(curve.timesUs, [0, 1000])
    XCTAssertEqual(curve.volumes, [1, 0.5])
    XCTAssertNil(VolumeCurve.from([Double.nan, 0.5] as [NSNumber]))
  }

  // MARK: - Helpers

  /// Frames of `level` on both channels, faded, read back as the left channel.
  /// Both channels get the same gain, which is asserted here too.
  private func fadedBody(
    frames: Int, fadeInFrames: Int, fadeOutFrames: Int, level: Int16? = nil
  ) -> [Int16] {
    var pcm = levelFrames(frames, level: level ?? self.level)
    AudioPreRenderer.applyFade(
      to: &pcm,
      audibleBytes: pcm.count,
      bytesPerFrame: bytesPerFrame,
      fadeInFrames: fadeInFrames,
      fadeOutFrames: fadeOutFrames
    )
    let left = leftSamples(pcm)
    XCTAssertEqual(left, rightSamples(pcm), "both channels share one gain")
    return left
  }

  private func levelFrames(_ frames: Int, level: Int16) -> Data {
    var data = Data()
    for _ in 0..<(frames * 2) {
      var sample = level.littleEndian
      withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
    return data
  }

  private func leftSamples(_ pcm: Data) -> [Int16] { samples(pcm, channel: 0) }

  private func rightSamples(_ pcm: Data) -> [Int16] { samples(pcm, channel: 1) }

  private func samples(_ pcm: Data, channel: Int) -> [Int16] {
    stride(from: 0, to: pcm.count, by: bytesPerFrame).map { frameStart in
      let offset = frameStart + channel * 2
      let bits = UInt16(pcm[offset]) | (UInt16(pcm[offset + 1]) << 8)
      return Int16(bitPattern: bits)
    }
  }
}

// MARK: - Overlap transition crossfade

/// The audio cross-fade `ClipTransitionRenderer` gives an overlap transition:
/// each side follows the transition's curve, as the video and the Android
/// export do, instead of a straight line.
final class TransitionCrossfadeTests: XCTestCase {
  private let sampleRate = 44_100.0
  /// The source tone's peak.
  private let toneLevel: Float = 0.5
  private let blend = CMTime(value: 1_000_000, timescale: 1_000_000)

  /// A quarter into an easeIn blend the outgoing clip still plays at 15/16 of
  /// its volume (a straight fade would be at 3/4), and halfway the incoming
  /// clip has only reached a quarter of its own (a straight fade: half).
  func testEachSideFollowsTheTransitionCurve() async throws {
    let tone = try writeTone()

    // One side at a time, the other muted, so the level read is that side's.
    let fadingOut = try await crossfadeLevel(
      tone, outgoing: .init(volume: 0.8), incoming: .init(volume: 0), curve: "easeIn")
    XCTAssertEqual(fadingOut(0.25), toneLevel * 0.8 * 15 / 16, accuracy: 0.01)
    XCTAssertEqual(fadingOut(0.5), toneLevel * 0.8 * 3 / 4, accuracy: 0.01)

    let fadingIn = try await crossfadeLevel(
      tone, outgoing: .init(volume: 0), incoming: .init(volume: 1), curve: "easeIn")
    XCTAssertEqual(fadingIn(0.5), toneLevel / 4, accuracy: 0.01)
    XCTAssertEqual(fadingIn(0.75), toneLevel * 9 / 16, accuracy: 0.01)
  }

  /// elasticOut springs to about 1.3 a sixth of the way in, where Android
  /// plays the incoming clip that much louder; here it holds at its volume.
  func testAnElasticOvershootHoldsEachSideAtItsEndVolume() async throws {
    XCTAssertGreaterThan(applyEasing(5.0 / 30, curve: "elasticOut"), 1.2)
    let rising = ClipTransitionRenderer.crossfadeRamps(
      volume: 0.8, fadesIn: true, curve: "elasticOut", duration: blend, steps: 30)
    let falling = ClipTransitionRenderer.crossfadeRamps(
      volume: 0.8, fadesIn: false, curve: "elasticOut", duration: blend, steps: 30)

    XCTAssertEqual(rising[4].to, 0.8)
    XCTAssertEqual(falling[4].to, 0)
    for ramp in rising + falling {
      XCTAssertTrue((0...0.8).contains(ramp.from) && (0...0.8).contains(ramp.to))
    }

    // The hold is a run of flat ramps. A mix plays a flat ramp at its volume
    // only when the ramp before ends there (see `setVolumeSteps`), so the mix
    // is read back too.
    let tone = try writeTone()
    let fadingIn = try await crossfadeLevel(
      tone, outgoing: .init(volume: 0), incoming: .init(volume: 0.8), curve: "elasticOut")
    XCTAssertEqual(fadingIn(0.15), toneLevel * 0.8, accuracy: 0.01)
    let fadingOut = try await crossfadeLevel(
      tone, outgoing: .init(volume: 0.8), incoming: .init(volume: 0), curve: "elasticOut")
    XCTAssertEqual(fadingOut(0.15), 0, accuracy: 0.01)
  }

  // MARK: - Helpers

  /// One second of a 440 Hz stereo tone at `toneLevel`, in a file removed
  /// after the test.
  private func writeTone() throws -> AVURLAsset {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("crossfade-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("tone.caf")
    let frames = AVAudioFrameCount(sampleRate)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<2 {
      for frame in 0..<Int(frames) {
        buffer.floatChannelData![channel][frame] =
          toneLevel * sin(Float(frame) * 2 * .pi * 440 / Float(sampleRate))
      }
    }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    return AVURLAsset(url: url)
  }

  /// Cross-fades [tone] with itself over `blend` and reads the mix back as
  /// float through an asset reader. Returns the tone's peak around a point of
  /// the blend, given as a fraction of it.
  private func crossfadeLevel(
    _ tone: AVURLAsset,
    outgoing: ClipTransitionRenderer.SideAudio,
    incoming: ClipTransitionRenderer.SideAudio,
    curve: String
  ) async throws -> (Double) -> Float {
    let composition = AVMutableComposition()
    let mix = try await ClipTransitionRenderer.buildAudioMix(
      composition: composition,
      outAsset: tone, outStart: .zero, outDuration: blend,
      inAsset: tone, inStart: .zero, inDuration: blend,
      duration: blend, curve: curve, steps: 30,
      outgoingAudio: outgoing, incomingAudio: incoming)

    let reader = try AVAssetReader(asset: composition)
    let output = AVAssetReaderAudioMixOutput(
      audioTracks: composition.tracks(withMediaType: .audio),
      audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    output.audioMix = try XCTUnwrap(mix)
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var left: [Float] = []
    while let buffer = output.copyNextSampleBuffer(),
      let block = CMSampleBufferGetDataBuffer(buffer)
    {
      var interleaved = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
      CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: interleaved.count * 4, destination: &interleaved)
      left += stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] }
    }
    XCTAssertEqual(reader.status, .completed, String(describing: reader.error))

    let samples = left
    let rate = sampleRate
    // One 440 Hz cycle around the point.
    return { fraction in
      let center = Int(fraction * rate)
      return samples[(center - 50)...(center + 50)].map(abs).max() ?? 0
    }
  }
}

/// Custom-track speed is baked before looping and fades, without scaling
/// composition edits that would introduce silent gaps around audio edits.
final class AudioTrackSpeedTests: XCTestCase {
  private let rate = 16000

  func testDurationPitchAndStereoAtEachSpeed() {
    let source = tone(seconds: 3)
    for speed in [0.25, 0.5, 1.5, 2, 3] {
      let output = AudioTimeStretch.stretch(
        source, sampleRate: rate, channels: 2, speed: speed, maxFrames: rate * 12)
      XCTAssertEqual(output.count / 4, Int(ceil(Double(rate * 3) / speed)))
      XCTAssertEqual(frequency(output, channel: 0), 440, accuracy: 5)
      XCTAssertEqual(frequency(output, channel: 1), 660, accuracy: 5)
    }
  }

  func testOppositePhaseStereoDoesNotCancelOrLosePitch() {
    let output = AudioTimeStretch.stretch(
      tone(seconds: 2, opposite: true), sampleRate: rate, channels: 2,
      speed: 0.5, maxFrames: rate * 4)
    output.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      for frame in 0..<(samples.count / 2) {
        XCTAssertEqual(Int(samples[frame * 2]) + Int(samples[frame * 2 + 1]), 0)
      }
    }
    XCTAssertEqual(frequency(output, channel: 0), 440, accuracy: 5)
  }

  func testSoundStartsOnTheFirstSampleAndEndsAtFullLevel() {
    let source = periodicTone(seconds: 2)
    for speed in [0.5, 0.8, 1.25, 2, 3] {
      let output = AudioTimeStretch.stretch(
        source, sampleRate: rate, channels: 2, speed: speed, maxFrames: rate * 12)
      XCTAssertEqual(output.prefix(400), source.prefix(400), "start at \(speed)")
      assertQuietestPeriod(output, above: 0.95, "once at \(speed)")
    }
  }

  func testLoopStretchesEachSeamWithoutAGap() {
    let source = periodicTone(seconds: 1)
    for speed in [0.5, 0.8, 1.25, 2, 3] {
      let output = AudioTimeStretch.stretch(
        source, sampleRate: rate, channels: 2, speed: speed, maxFrames: rate * 5, loop: true)
      XCTAssertEqual(output.count, rate * 5 * 4, "body length at \(speed)")
      assertQuietestPeriod(output, above: 0.95, "loop at \(speed)")
    }
  }

  func testUnityIsExactAndRenderingStopsAtTheOutputSlot() {
    let source = tone(seconds: 2)
    XCTAssertEqual(AudioTimeStretch.stretch(
      source, sampleRate: rate, channels: 2, speed: 1, maxFrames: rate * 2), source)
    let short = AudioTimeStretch.stretch(
      source, sampleRate: rate, channels: 2, speed: 0.25, maxFrames: rate)
    XCTAssertEqual(short.count, rate * 4)
    XCTAssertEqual(frequency(short, channel: 0), 440, accuracy: 5)
  }

  private func tone(seconds: Int, opposite: Bool = false) -> Data {
    var pcm = Data()
    for frame in 0..<(rate * seconds) {
      let left = Int16(12000 * sin(2 * .pi * 440 * Double(frame) / Double(rate)))
      let right = opposite ? -left : Int16(6000 * sin(2 * .pi * 660 * Double(frame) / Double(rate)))
      for sample in [left, right] {
        var value = sample.littleEndian
        withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
      }
    }
    return pcm
  }

  /// A 400 Hz tone of whole periods, so the source loops without a jump.
  private func periodicTone(seconds: Int) -> Data {
    var pcm = Data()
    for frame in 0..<(rate * seconds) {
      var value = Int16((12000 * sin(2 * .pi * 400 * Double(frame) / Double(rate))).rounded())
        .littleEndian
      for _ in 0..<2 { withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) } }
    }
    return pcm
  }

  /// Fails when any whole 400 Hz period peaks below `share` of the tone.
  private func assertQuietestPeriod(_ pcm: Data, above share: Double, _ message: String) {
    pcm.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      let period = rate / 400
      for start in Swift.stride(from: 0, through: samples.count / 2 - period, by: period) {
        let peak = (start..<(start + period)).map { abs(Int(samples[$0 * 2])) }.max() ?? 0
        if Double(peak) < 12000 * share {
          XCTFail("\(message): peak \(peak) at frame \(start)")
          return
        }
      }
    }
  }

  private func frequency(_ pcm: Data, channel: Int) -> Double {
    pcm.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      let from = rate / 4
      let to = from + rate / 2
      var crossings = 0
      var peak = 0
      for frame in from..<to {
        if (samples[(frame - 1) * 2 + channel] < 0) != (samples[frame * 2 + channel] < 0) {
          crossings += 1
        }
        peak = max(peak, abs(Int(samples[frame * 2 + channel])))
      }
      XCTAssertGreaterThan(peak, 1000)
      return Double(crossings)
    }
  }
}
