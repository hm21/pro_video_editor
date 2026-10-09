import Foundation

/// Raises or lowers parts of a clip's or a track's audio with a cascade of
/// [bands], applied in order.
struct AudioEqualizer: Equatable {
  /// One filter of the equalizer: a shelf or a peak at [frequencyHz].
  struct Band: Equatable {
    /// The shape of a band's filter.
    enum Kind: String {
      /// Raises or lowers everything below the band's frequency.
      case lowShelf
      /// Raises or lowers a bell around the band's frequency, as wide as its Q.
      case peak
      /// Raises or lowers everything above the band's frequency.
      case highShelf
    }

    /// 1/√2, the Q of a band that names none.
    static let defaultQ = 0.7071067811865476

    let kind: Kind
    /// Corner of a shelf or center of a peak, above 0.
    let frequencyHz: Double
    /// How far the band is raised (positive) or lowered (negative), in decibels.
    let gainDb: Double
    /// How narrow a peak is; shelves ignore it and have a slope of 1.
    let q: Double

    init(kind: Kind, frequencyHz: Double, gainDb: Double = 0, q: Double = defaultQ) {
      self.kind = kind
      self.frequencyHz = frequencyHz
      self.gainDb = gainDb
      self.q = q
    }

    /// Parses a band from a platform-channel map; nil for an unknown type or
    /// a frequency that is not above 0, so the caller skips it.
    static func from(_ map: Any?) -> Band? {
      guard let map = map as? [String: Any],
        let kind = (map["type"] as? String).flatMap(Kind.init(rawValue:)),
        let frequencyHz = (map["frequencyHz"] as? NSNumber)?.doubleValue,
        frequencyHz > 0, frequencyHz.isFinite
      else { return nil }
      let q = (map["q"] as? NSNumber)?.doubleValue ?? defaultQ
      return Band(
        kind: kind,
        frequencyHz: frequencyHz,
        gainDb: (map["gainDb"] as? NSNumber)?.doubleValue ?? 0,
        q: q > 0 ? q : defaultQ)
    }
  }

  /// The filters, in the order they are applied.
  let bands: [Band]

  init(bands: [Band] = []) {
    self.bands = bands
  }

  /// Whether the equalizer leaves the audio unchanged.
  var isFlat: Bool { bands.allSatisfy { $0.gainDb == 0 } }

  /// Whether any band raises the audio, which can cross full scale.
  var boosts: Bool { bands.contains { $0.gainDb > 0 } }

  /// Parses an equalizer from a platform-channel map, skipping the bands it
  /// cannot parse; nil when the map is absent or leaves the audio unchanged,
  /// so a flat one costs nothing.
  static func from(_ map: Any?) -> AudioEqualizer? {
    guard let bands = (map as? [String: Any])?["bands"] as? [Any] else { return nil }
    let equalizer = AudioEqualizer(bands: bands.compactMap(Band.from))
    return equalizer.isFlat ? nil : equalizer
  }
}

/// One second-order section, normalised so `a0` is 1.
struct Biquad: Equatable {
  let b0: Double
  let b1: Double
  let b2: Double
  let a1: Double
  let a2: Double

  /// The highest frequency a section gets, as a fraction of the sample rate:
  /// close to half of it the bilinear transform squeezes the filter flat.
  static let maxCornerRatio = 0.45

  /// The section that passes the signal unchanged.
  static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

  /// The cookbook's section for [band].
  static func forBand(_ band: AudioEqualizer.Band, sampleRate: Double) -> Biquad {
    switch band.kind {
    case .lowShelf:
      return lowShelf(frequencyHz: band.frequencyHz, gainDb: band.gainDb, sampleRate: sampleRate)
    case .peak:
      return peak(
        frequencyHz: band.frequencyHz, gainDb: band.gainDb, q: band.q, sampleRate: sampleRate)
    case .highShelf:
      return highShelf(frequencyHz: band.frequencyHz, gainDb: band.gainDb, sampleRate: sampleRate)
    }
  }

  /// The cookbook's low shelf at [frequencyHz], slope 1.
  static func lowShelf(frequencyHz: Double, gainDb: Double, sampleRate: Double) -> Biquad {
    shelf(frequencyHz: frequencyHz, gainDb: gainDb, sampleRate: sampleRate, high: false)
  }

  /// The cookbook's high shelf at [frequencyHz], slope 1.
  static func highShelf(frequencyHz: Double, gainDb: Double, sampleRate: Double) -> Biquad {
    shelf(frequencyHz: frequencyHz, gainDb: gainDb, sampleRate: sampleRate, high: true)
  }

  /// The cookbook's peak at [frequencyHz], as narrow as [q].
  static func peak(frequencyHz: Double, gainDb: Double, q: Double, sampleRate: Double) -> Biquad {
    guard gainDb != 0 else { return identity }
    let rate = max(sampleRate, 1)
    let a = pow(10, gainDb / 40)
    let w0 = 2 * Double.pi * corner(frequencyHz, rate: rate) / rate
    let alpha = sin(w0) / (2 * q)
    let a0 = 1 + alpha / a
    let b1 = -2 * cos(w0) / a0
    return Biquad(
      b0: (1 + alpha * a) / a0,
      b1: b1,
      b2: (1 - alpha * a) / a0,
      a1: b1,
      a2: (1 - alpha / a) / a0)
  }

  private static func corner(_ frequencyHz: Double, rate: Double) -> Double {
    min(max(frequencyHz, 1), rate * maxCornerRatio)
  }

  private static func shelf(
    frequencyHz: Double,
    gainDb: Double,
    sampleRate: Double,
    high: Bool
  ) -> Biquad {
    guard gainDb != 0 else { return identity }
    let rate = max(sampleRate, 1)
    let a = pow(10, gainDb / 40)
    let w0 = 2 * Double.pi * corner(frequencyHz, rate: rate) / rate
    let cosW0 = cos(w0)
    // alpha = sin(w0) / 2 * sqrt((A + 1/A) * (1/S - 1) + 2) with S = 1.
    let alpha = sin(w0) / 2 * 2.0.squareRoot()
    let twoSqrtAAlpha = 2 * a.squareRoot() * alpha
    let b0: Double
    let b1: Double
    let b2: Double
    let a0: Double
    let a1: Double
    let a2: Double
    if high {
      b0 = a * ((a + 1) + (a - 1) * cosW0 + twoSqrtAAlpha)
      b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
      b2 = a * ((a + 1) + (a - 1) * cosW0 - twoSqrtAAlpha)
      a0 = (a + 1) - (a - 1) * cosW0 + twoSqrtAAlpha
      a1 = 2 * ((a - 1) - (a + 1) * cosW0)
      a2 = (a + 1) - (a - 1) * cosW0 - twoSqrtAAlpha
    } else {
      b0 = a * ((a + 1) - (a - 1) * cosW0 + twoSqrtAAlpha)
      b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
      b2 = a * ((a + 1) - (a - 1) * cosW0 - twoSqrtAAlpha)
      a0 = (a + 1) + (a - 1) * cosW0 + twoSqrtAAlpha
      a1 = -2 * ((a - 1) + (a + 1) * cosW0)
      a2 = (a + 1) + (a - 1) * cosW0 - twoSqrtAAlpha
    }
    return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
  }
}

/// Raises or lowers parts of audio through the [AudioEqualizer.bands], one
/// second-order section per band, in band order.
///
/// The sections are the low shelf, peak and high shelf of Robert
/// Bristow-Johnson's Audio EQ Cookbook. A shelf has a slope of 1, the steepest
/// that does not overshoot: half the gain at the corner, all of it an octave
/// or two beyond. A peak has the band's Q. Each channel keeps its own filter
/// state, in double precision, in transposed direct form II; a band without
/// gain is left out.
///
/// The Android export and `divine_video_player`'s preview run twins of this
/// type with the same formulas, so a preview sounds like the export.
///
/// A class rather than a struct: it carries filter state from one buffer to
/// the next, and a copy would quietly fork that history.
final class BandEqualizer {
  let equalizer: AudioEqualizer
  private let filters: [Biquad]
  /// Two delay elements per channel per filter.
  private var state: [Double]
  private let channels: Int

  init(equalizer: AudioEqualizer, sampleRate: Double, channelCount: Int) {
    self.equalizer = equalizer
    filters = equalizer.bands
      .filter { $0.gainDb != 0 }
      .map { Biquad.forBand($0, sampleRate: sampleRate) }
    channels = max(channelCount, 1)
    state = Array(repeating: 0, count: filters.count * channels * 2)
  }

  /// Filters one sample of [channel].
  func process(_ sample: Float, channel: Int) -> Float {
    guard channel < channels else { return sample }
    var x = Double(sample)
    for (index, filter) in filters.enumerated() {
      let z = (index * channels + channel) * 2
      let y = filter.b0 * x + state[z]
      state[z] = filter.b1 * x - filter.a1 * y + state[z + 1]
      state[z + 1] = filter.b2 * x - filter.a2 * y
      x = y
    }
    return Float(x)
  }

  /// Filters interleaved [samples] of the equalizer's channel count in place.
  func process(interleaved samples: inout [Float]) {
    for index in samples.indices {
      samples[index] = process(samples[index], channel: index % channels)
    }
  }

  /// Forgets the filters' history, e.g. after a seek.
  func reset() {
    for index in state.indices { state[index] = 0 }
  }
}
