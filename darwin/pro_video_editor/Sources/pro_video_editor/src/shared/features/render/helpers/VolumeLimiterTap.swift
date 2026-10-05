import AVFoundation
import MediaToolbox

/// The volume an audio mix applies to one track, by time on that track.
struct VolumeSchedule {
  struct Entry {
    let start: Double
    let end: Double
    let volume: Float
  }

  let entries: [Entry]

  /// The volumes a mix sets over [ranges], in seconds.
  init(_ ranges: [(range: CMTimeRange, volume: Float)]) {
    entries = ranges.map {
      Entry(start: $0.range.start.seconds, end: $0.range.end.seconds, volume: $0.volume)
    }
  }

  /// One [volume] for the whole track.
  init(constant volume: Float) {
    entries = [Entry(start: -.infinity, end: .infinity, volume: volume)]
  }

  /// Whether any part of the track is played above its own level.
  var amplifies: Bool { entries.contains { $0.volume > 1 } }

  /// The highest volume anywhere on the track.
  var loudest: Float { entries.map(\.volume).max() ?? 1 }

  /// The volume at [seconds]; 1 where the mix sets none.
  func volume(at seconds: Double) -> Float {
    entries.first { seconds >= $0.start && seconds < $0.end }?.volume ?? 1
  }
}

/// Limits one track of an audio mix so the volume the mix applies to it never
/// pushes it past full scale; see [PeakLimiter].
///
/// A mix applies its volume after the tap — measured on an export session: a
/// tap on a track at volume 3 sees the source level while the file comes out
/// three times louder. The tap therefore leaves the volume to the mix and only
/// turns down the frames that volume would push past the ceiling.
enum VolumeLimiterTap {
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
      for frame in 0..<frameCount {
        // Without a time the loudest volume is the safe assumption.
        let volume =
          startSeconds.map { schedule.volume(at: $0 + Double(frame) / sampleRate) }
          ?? schedule.loudest
        var peak: Float = 0
        forEachSample(in: buffers, frame: frame) { peak = max(peak, abs($0.pointee)) }
        let gain = limiter.gain(forPeak: peak * volume)
        guard gain < 1 else { continue }
        forEachSample(in: buffers, frame: frame) { $0.pointee *= gain }
      }
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
