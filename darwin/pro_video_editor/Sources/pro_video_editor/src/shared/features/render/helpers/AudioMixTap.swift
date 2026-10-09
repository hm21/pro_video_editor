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

/// The equalizer applied to one track of an audio mix, by time on that track.
///
/// Clips share one composition track, so a clip's equalizer is the one whose
/// range has started; see [AudioMixTap].
struct EqualizerSchedule {
  struct Entry {
    let start: Double
    let equalizer: AudioEqualizer?
  }

  /// Sorted by start.
  let entries: [Entry]

  /// No equalizer anywhere on the track.
  static let flat = EqualizerSchedule(constant: nil)

  /// The equalizers set over [ranges], in seconds.
  init(_ ranges: [(range: CMTimeRange, equalizer: AudioEqualizer?)]) {
    entries = ranges.map { Entry(start: $0.range.start.seconds, equalizer: $0.equalizer) }
      .sorted { $0.start < $1.start }
  }

  /// One [equalizer] for the whole track.
  init(constant equalizer: AudioEqualizer?) {
    entries = [Entry(start: -.infinity, equalizer: equalizer)]
  }

  /// Whether no part of the track is equalized.
  var isFlat: Bool { entries.allSatisfy { $0.equalizer?.isFlat ?? true } }

  /// The index of the entry in effect at [seconds]: the last that started by
  /// then, or nil before the first.
  func entryIndex(at seconds: Double) -> Int? {
    var low = 0
    var high = entries.count
    while low < high {
      let mid = (low + high) / 2
      if entries[mid].start <= seconds { low = mid + 1 } else { high = mid }
    }
    return low == 0 ? nil : low - 1
  }
}

extension AVMutableAudioMixInputParameters {
  /// How long a range takes to reach its volume from the one before it.
  static let volumeStepRamp = CMTime(value: 1, timescale: 1000)

  /// Plays the track at each step's volume from the start of its range, with
  /// [equalizers] applied, and limits it where a volume above 1.0 or a
  /// boosting equalizer would clip; see [AudioMixTap].
  ///
  /// Each range opens with a [volumeStepRamp] from the volume before it. Given
  /// one flat ramp per range instead, a mix does not switch where a range of
  /// 2 s or less starts: it fades from the previous volume across the whole
  /// range (measured on export sessions and asset readers), so a clip after a
  /// louder one played louder almost to its end.
  func setVolumeSteps(
    _ steps: [(range: CMTimeRange, volume: Float)],
    equalizers: EqualizerSchedule = .flat
  ) {
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
    audioTapProcessor = AudioMixTap.make(volumes: VolumeSchedule(steps), equalizers: equalizers)
  }
}

/// Equalizes one track of an audio mix and limits it so neither a boosting
/// equalizer nor the volume the mix applies pushes it past full scale; see
/// [BandEqualizer] and [PeakLimiter].
///
/// A track carries one tap, so both jobs share it, in the order the Android
/// export runs them: the equalizer, limited on its own while it boosts, then
/// the volume's limiter.
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
/// gets louder and let one that gets quieter clip for up to 50 ms. The
/// equalizer switches exactly at the cut, starting from silence when it
/// changes there, as each clip's own chain does on Android.
enum AudioMixTap {
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

  /// How far a buffer may start from where the one before it ended and still
  /// count as the track playing on. A time-scaled track (a clip's speed, the
  /// global speed, a transition side) stamps its buffers up to two samples off
  /// that point (measured); taking each of those for a seek started the
  /// equalizer over mid-tone, an audible click at every buffer.
  static let seekToleranceSeconds = 0.002

  /// A tap for a track the mix plays at [volumes] with [equalizers], or nil
  /// when the volume never amplifies and nothing is equalized, or the tap
  /// cannot be created.
  static func make(
    volumes: VolumeSchedule,
    equalizers: EqualizerSchedule = .flat
  ) -> MTAudioProcessingTap? {
    guard volumes.amplifies || !equalizers.isFlat else { return nil }
    let context = Context(volumes: volumes, equalizers: equalizers)
    let clientInfo = Unmanaged.passRetained(context).toOpaque()
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
          .process(bufferList, frameCount: Int(frameCountOut.pointee), start: timeRange.start)
      }
    )
    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(
      kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    guard status == noErr, let tap else {
      // Without a tap there is no finalize to balance the retain.
      Unmanaged<Context>.fromOpaque(clientInfo).release()
      PluginLog.print(
        "⚠️ Audio mix tap not created (\(status)); the track may clip or play unequalized")
      return nil
    }
    return tap
  }

  /// The tap's state, owned by the tap from `init` until `finalize`.
  final class Context {
    let volumes: VolumeSchedule
    let equalizers: EqualizerSchedule
    private var limiter = PeakLimiter(sampleRate: 44_100)
    private var equalizerLimiter = PeakLimiter(sampleRate: 44_100)
    private var sampleRate: Double = 44_100
    private var channelCount = 2
    private var isFloat = false
    /// The volume the mix applies at the next frame, nil until the first
    /// frame and after a jump in time.
    private var mixVolume: Float?
    /// Where the next buffer starts if the track plays on without a jump.
    private var nextStart: Double?
    /// The filters of the equalizer entry in effect, nil while it is flat.
    private var filters: BandEqualizer?
    /// The equalizer entry [filters] belongs to, nil until the first frame and
    /// after a jump in time.
    private var filterEntry: Int?

    init(volumes: VolumeSchedule, equalizers: EqualizerSchedule = .flat) {
      self.volumes = volumes
      self.equalizers = equalizers
    }

    func prepare(_ format: AudioStreamBasicDescription) {
      sampleRate = format.mSampleRate
      channelCount = max(Int(format.mChannelsPerFrame), 1)
      // The mix hands taps 32-bit float; anything else passes unprocessed
      // rather than being read as the wrong type.
      isFloat =
        format.mFormatID == kAudioFormatLinearPCM
        && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        && format.mBitsPerChannel == 32
      limiter = PeakLimiter(sampleRate: sampleRate)
      equalizerLimiter = PeakLimiter(sampleRate: sampleRate)
      mixVolume = nil
      nextStart = nil
      filters = nil
      filterEntry = nil
    }

    /// Equalizes and limits [frameCount] frames that start at [start] on the
    /// track, in interleaved or one-channel-per-buffer float.
    func process(
      _ list: UnsafeMutablePointer<AudioBufferList>,
      frameCount: Int,
      start: CMTime
    ) {
      guard isFloat, frameCount > 0 else { return }
      let buffers = UnsafeMutableAudioBufferListPointer(list)
      let startSeconds = start.isNumeric ? start.seconds : nil
      if let startSeconds, let nextStart,
        abs(startSeconds - nextStart) > AudioMixTap.seekToleranceSeconds
      {
        // A seek: the mix starts over at the volume set there, and the
        // filters' history belongs to audio that no longer follows.
        mixVolume = nil
        filterEntry = nil
        filters?.reset()
        equalizerLimiter.reset()
      }
      nextStart = startSeconds.map { $0 + Double(frameCount) / sampleRate }
      let equalizes = !equalizers.isFlat
      let amplifies = volumes.amplifies
      let glideStep = AudioMixTap.glidePerSecond / Float(sampleRate)
      for frame in 0..<frameCount {
        let seconds = startSeconds.map { $0 + Double(frame) / sampleRate }
        if equalizes { equalize(buffers, frame: frame, at: seconds) }
        guard amplifies else { continue }
        // Without a time the loudest volume is the safe assumption.
        let volume = seconds.map { glide(at: $0, step: glideStep) } ?? volumes.loudest
        var peak: Float = 0
        forEachSample(in: buffers, frame: frame) { sample, _ in
          peak = max(peak, abs(sample.pointee))
        }
        let gain = limiter.gain(forPeak: peak * volume)
        guard gain < 1 else { continue }
        forEachSample(in: buffers, frame: frame) { sample, _ in sample.pointee *= gain }
      }
    }

    /// Runs one frame, at [seconds] on the track, through the equalizer in
    /// effect there, and limits it while that equalizer boosts.
    private func equalize(
      _ buffers: UnsafeMutableAudioBufferListPointer,
      frame: Int,
      at seconds: Double?
    ) {
      // Without a time the entry stays the one already playing, or, before
      // any has played, the one a constant schedule sets for the whole track.
      let entry =
        seconds.flatMap { equalizers.entryIndex(at: $0) } ?? filterEntry
        ?? equalizers.entryIndex(at: -.infinity)
      if entry != filterEntry {
        let equalizer = entry.flatMap { equalizers.entries[$0].equalizer }
          .flatMap { $0.isFlat ? nil : $0 }
        if equalizer != filters?.equalizer {
          filters = equalizer.map {
            BandEqualizer(equalizer: $0, sampleRate: sampleRate, channelCount: channelCount)
          }
          equalizerLimiter.reset()
        }
        filterEntry = entry
      }
      guard let filters else { return }
      var peak: Float = 0
      forEachSample(in: buffers, frame: frame) { sample, channel in
        sample.pointee = filters.process(sample.pointee, channel: channel)
        peak = max(peak, abs(sample.pointee))
      }
      guard filters.equalizer.boosts else { return }
      let gain = equalizerLimiter.gain(forPeak: peak)
      guard gain < 1 else { return }
      forEachSample(in: buffers, frame: frame) { sample, _ in sample.pointee *= gain }
    }

    /// Moves the mix's volume one frame, at [seconds], toward the scheduled
    /// one the way the mix does, and returns it.
    private func glide(at seconds: Double, step: Float) -> Float {
      let target = max(
        volumes.volume(at: seconds),
        volumes.volume(at: seconds + AudioMixTap.riseLeadSeconds))
      let current = mixVolume ?? target
      let next = target > current ? min(target, current + step) : max(target, current - step)
      if next < current { limiter.volumeDropped(by: current / next) }
      mixVolume = next
      return next
    }

    /// Calls [body] with every sample of [frame] and its channel, counted
    /// across the buffers so one-channel-per-buffer audio numbers its
    /// channels like interleaved audio does.
    private func forEachSample(
      in buffers: UnsafeMutableAudioBufferListPointer,
      frame: Int,
      _ body: (UnsafeMutablePointer<Float>, Int) -> Void
    ) {
      var channelIndex = 0
      for buffer in buffers {
        let channels = max(Int(buffer.mNumberChannels), 1)
        defer { channelIndex += channels }
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        guard (frame + 1) * channels * MemoryLayout<Float>.size <= Int(buffer.mDataByteSize)
        else { continue }
        for channel in 0..<channels {
          body(data + frame * channels + channel, channelIndex + channel)
        }
      }
    }
  }
}
