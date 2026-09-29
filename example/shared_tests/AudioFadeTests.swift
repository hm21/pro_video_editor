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
