import AVFoundation
import MediaToolbox

/// The volume an audio mix applies to one track, by time on that track.
struct VolumeSchedule {
  struct Entry {
    let start: Double
    let volume: Float
  }

  /// Sorted by start.
  let entries: [Entry]

  /// The volumes a mix sets over [ranges], in seconds.
  init(_ ranges: [(range: CMTimeRange, volume: Float)]) {
    entries = ranges.map { Entry(start: $0.range.start.seconds, volume: $0.volume) }
      .sorted { $0.start < $1.start }
  }

  /// One [volume] for the whole track.
  init(constant volume: Float) {
    entries = [Entry(start: -.infinity, volume: volume)]
  }

  /// Whether any part of the track is played above its own level.
  var amplifies: Bool { entries.contains { $0.volume > 1 } }

  /// The highest volume anywhere on the track.
  var loudest: Float { entries.map(\.volume).max() ?? 1 }

  /// The volume at [seconds]: 1 before the first range, else that of the
  /// last range that started by then, since a mix holds a volume through a
  /// gap until the next range sets another.
  func volume(at seconds: Double) -> Float {
    var low = 0
    var high = entries.count
    while low < high {
      let mid = (low + high) / 2
      if entries[mid].start <= seconds { low = mid + 1 } else { high = mid }
    }
    return low == 0 ? 1 : entries[low - 1].volume
  }
}

extension AVMutableAudioMixInputParameters {
  /// How long a range takes to reach its volume from the one before it.
  static let volumeStepRamp = CMTime(value: 1, timescale: 1000)

  /// Plays the track at each step's volume from the start of its range, and
  /// limits it where a volume above 1.0 would clip; see [VolumeLimiterTap].
  ///
  /// Each range opens with a [volumeStepRamp] from the volume before it. Given
  /// one flat ramp per range instead, a mix does not switch where a range of
  /// 2 s or less starts: it fades from the previous volume across the whole
  /// range (measured on export sessions and asset readers), so a clip after a
  /// louder one played louder almost to its end.
  func setVolumeSteps(_ steps: [(range: CMTimeRange, volume: Float)]) {
    var previous: Float?
    for step in steps.sorted(by: { $0.range.start < $1.range.start }) {
      var rest = step.range
      if let previous, previous != step.volume {
        let ramp = CMTimeRange(
          start: rest.start, duration: CMTimeMinimum(Self.volumeStepRamp, rest.duration))
        setVolumeRamp(fromStartVolume: previous, toEndVolume: step.volume, timeRange: ramp)
        rest = CMTimeRange(start: ramp.end, end: rest.end)
      }
      if rest.duration > .zero {
        setVolumeRamp(fromStartVolume: step.volume, toEndVolume: step.volume, timeRange: rest)
      }
      previous = step.volume
    }
    audioTapProcessor = VolumeLimiterTap.make(for: VolumeSchedule(steps))
  }
}

/// Limits one track of an audio mix so the volume the mix applies to it never
/// pushes it past full scale; see [PeakLimiter].
///
/// A mix applies its volume after the tap — measured on an export session and
/// an asset reader: a tap on a track at volume 3 sees the source level while
/// the output comes out three times louder. The tap therefore leaves the
/// volume to the mix and only turns down the frames that volume would push
/// past the ceiling.
///
/// Where the volume changes, at a cut between clips, the mix glides to the new
/// one at [glidePerSecond] rather than jumping; the tap follows the same glide.
/// Limiting for the new volume right at the cut instead dipped a clip that
/// gets louder and let one that gets quieter clip for up to 50 ms.
enum VolumeLimiterTap {
  /// How fast a mix moves to a new volume: 1.0 per 25 ms, from the start of
  /// the range that sets it. Measured on an export session and an asset
  /// reader, at 44.1 and 48 kHz; at the start of a track or a trim the mix
  /// begins at the volume set there.
  static let glidePerSecond: Float = 40

  /// How much earlier the tap lets a rising volume take effect. After a trim
  /// the mix started its first glide up to 3.5 ms before the range that set
  /// it; assuming the higher volume a little early never lets it run ahead of
  /// the limiter.
  static let riseLeadSeconds = 0.005

  /// A tap for a track the mix plays at [schedule], or nil when the schedule
  /// never amplifies or the tap cannot be created.
  static func make(for schedule: VolumeSchedule) -> MTAudioProcessingTap? {
    guard schedule.amplifies else { return nil }
    let clientInfo = Unmanaged.passRetained(Context(schedule: schedule)).toOpaque()
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: clientInfo,
      init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
      finalize: { tap in
        Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
      },
      prepare: { tap, _, format in
        Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
          .takeUnretainedValue()
          .prepare(format.pointee)
      },
      unprepare: nil,
      process: { tap, frameCount, _, bufferList, frameCountOut, flagsOut in
        var timeRange = CMTimeRange()
        let status = MTAudioProcessingTapGetSourceAudio(
          tap, frameCount, bufferList, flagsOut, &timeRange, frameCountOut)
        guard status == noErr else { return }
        Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
          .takeUnretainedValue()
          .limit(bufferList, frameCount: Int(frameCountOut.pointee), start: timeRange.start)
      }
    )
    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(
      kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    guard status == noErr, let tap else {
      // Without a tap there is no finalize to balance the retain.
      Unmanaged<Context>.fromOpaque(clientInfo).release()
      PluginLog.print("⚠️ Volume limiter tap not created (\(status)); the track may clip")
      return nil
    }
    return tap
  }

  /// The tap's state, owned by the tap from `init` until `finalize`.
  final class Context {
    let schedule: VolumeSchedule
    private var limiter = PeakLimiter(sampleRate: 44_100)
    private var sampleRate: Double = 44_100
    private var isFloat = false
    /// The volume the mix applies at the next frame, nil until the first
    /// frame and after a jump in time.
    private var mixVolume: Float?
    /// Where the next buffer starts if the track plays on without a jump.
    private var nextStart: Double?

    init(schedule: VolumeSchedule) {
      self.schedule = schedule
    }

    func prepare(_ format: AudioStreamBasicDescription) {
      sampleRate = format.mSampleRate
      // The mix hands taps 32-bit float; anything else passes unlimited
      // rather than being read as the wrong type.
      isFloat =
        format.mFormatID == kAudioFormatLinearPCM
        && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        && format.mBitsPerChannel == 32
      limiter = PeakLimiter(sampleRate: sampleRate)
      mixVolume = nil
      nextStart = nil
    }

    /// Limits [frameCount] frames that start at [start] on the track, in
    /// interleaved or one-channel-per-buffer float.
    func limit(
      _ list: UnsafeMutablePointer<AudioBufferList>,
      frameCount: Int,
      start: CMTime
    ) {
      guard isFloat, frameCount > 0 else { return }
      let buffers = UnsafeMutableAudioBufferListPointer(list)
      let startSeconds = start.isNumeric ? start.seconds : nil
      if let startSeconds, let nextStart, abs(startSeconds - nextStart) > 1 / sampleRate {
        // A seek: the mix starts over at the volume set there.
        mixVolume = nil
      }
      nextStart = startSeconds.map { $0 + Double(frameCount) / sampleRate }
      let glideStep = VolumeLimiterTap.glidePerSecond / Float(sampleRate)
      for frame in 0..<frameCount {
        // Without a time the loudest volume is the safe assumption.
        let volume =
          startSeconds.map { glide(at: $0 + Double(frame) / sampleRate, step: glideStep) }
          ?? schedule.loudest
        var peak: Float = 0
        forEachSample(in: buffers, frame: frame) { peak = max(peak, abs($0.pointee)) }
        let gain = limiter.gain(forPeak: peak * volume)
        guard gain < 1 else { continue }
        forEachSample(in: buffers, frame: frame) { $0.pointee *= gain }
      }
    }

    /// Moves the mix's volume one frame, at [seconds], toward the scheduled
    /// one the way the mix does, and returns it.
    private func glide(at seconds: Double, step: Float) -> Float {
      let target = max(
        schedule.volume(at: seconds),
        schedule.volume(at: seconds + VolumeLimiterTap.riseLeadSeconds))
      let current = mixVolume ?? target
      let next = target > current ? min(target, current + step) : max(target, current - step)
      if next < current { limiter.volumeDropped(by: current / next) }
      mixVolume = next
      return next
    }

    private func forEachSample(
      in buffers: UnsafeMutableAudioBufferListPointer,
      frame: Int,
      _ body: (UnsafeMutablePointer<Float>) -> Void
    ) {
      for buffer in buffers {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let channels = max(Int(buffer.mNumberChannels), 1)
        guard (frame + 1) * channels * MemoryLayout<Float>.size <= Int(buffer.mDataByteSize)
        else { continue }
        for channel in 0..<channels { body(data + frame * channels + channel) }
      }
    }
  }
}
