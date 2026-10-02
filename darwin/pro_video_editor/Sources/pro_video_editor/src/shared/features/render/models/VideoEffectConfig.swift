import Foundation

/// A horizontal slice of the frame that is shifted sideways.
///
/// Mirrors the Dart `VideoEffectBand`. `top` and `bottom` are fractions of the
/// frame height from the top edge, `shift` a fraction of its width; positive
/// moves the content right.
public struct VideoEffectBand: Sendable, Equatable {
  let top: Double
  let bottom: Double
  let shift: Double
}

/// The pixel operations of one frame of a video effect.
///
/// Mirrors the Dart `VideoEffectFrame`, which defines what every field means.
/// Dart decides what an effect looks like at each point in time and sends the
/// result as a table of these; this side only applies them. The per-pixel
/// definition is Kotlin's `VideoEffectMath`, and `applyVideoEffect(to:_:)`
/// implements it with Core Image.
public struct VideoEffectFrame: Sendable, Equatable {
  var pixelSize: Double = 0
  var rgbShift: Double = 0
  var scanlines: Double = 0
  var scanlinePeriod: Double = 0
  var noise: Double = 0
  var noiseCellSize: Double = 0
  var noiseOffsetX: Int = 0
  var noiseOffsetY: Int = 0
  var bands: [VideoEffectBand] = []
  var sepia: Double = 0
  var brightness: Double = 0
  var invert: Double = 0
  var flash: Double = 0
  var vignette: Double = 0
  var vignetteRadius: Double = 0
  var zoom: Double = 0
  var offsetX: Double = 0
  var offsetY: Double = 0
  var mirrorX: Double = 0
  var mirrorY: Double = 0
  var tiles: Int = 0
  var waveAmplitude: Double = 0
  var wavePeriod: Double = 0
  var wavePhase: Double = 0

  /// The most bands a frame carries.
  static let maxBands = 4

  /// The most times `tiles` repeats the picture across and down.
  static let maxTiles = 2

  /// The straight segments each wave is drawn with.
  static let waveSegments = 16

  /// The shortest wave period drawn, as a fraction of the frame height.
  static let minWavePeriod = 0.1

  /// Where the tone values start in a frame of the table, after the bands.
  private static let toneOffset = 9 + maxBands * 3

  /// Where the geometry values start in a frame of the table, after the tones.
  private static let geometryOffset = toneOffset + 6

  /// Values per frame in the table Dart sends.
  static let stride = geometryOffset + 9

  /// A frame that leaves the picture unchanged.
  static let none = VideoEffectFrame()

  /// Whether the frame leaves the picture unchanged.
  var isIdentity: Bool {
    pixelSize <= 0 && rgbShift == 0 && scanlines <= 0 && noise <= 0
      && bands.allSatisfy { $0.shift == 0 || $0.bottom <= $0.top }
      && sepia <= 0 && brightness == 0 && invert <= 0 && flash <= 0 && vignette <= 0
      && !hasTransform && tiles < 2 && !hasWave
  }

  /// Whether the first geometry stage zooms, moves or mirrors the picture.
  var hasTransform: Bool {
    zoom > 0 || offsetX != 0 || offsetY != 0 || mirrorX > 0 || mirrorY > 0
  }

  /// Whether the last geometry stage bends the rows.
  var hasWave: Bool { waveAmplitude != 0 && wavePeriod > 0 }

  /// How far the wave bends the rows, or 0 while it is off.
  private var waveStrength: Double { hasWave ? abs(waveAmplitude) : 0 }

  /// Combines two frames of overlapping effects, exactly as the Dart
  /// `VideoEffectFrame.merge` does.
  func merged(with other: VideoEffectFrame) -> VideoEffectFrame {
    if other.isIdentity { return self }
    if isIdentity { return other }
    let strongerScanlines = other.scanlines > scanlines ? other : self
    let strongerNoise = other.noise > noise ? other : self
    let strongerVignette = other.vignette > vignette ? other : self
    let strongerWave = other.waveStrength > waveStrength ? other : self
    return VideoEffectFrame(
      pixelSize: max(pixelSize, other.pixelSize),
      rgbShift: rgbShift + other.rgbShift,
      scanlines: strongerScanlines.scanlines,
      scanlinePeriod: strongerScanlines.scanlinePeriod,
      noise: strongerNoise.noise,
      noiseCellSize: strongerNoise.noiseCellSize,
      noiseOffsetX: strongerNoise.noiseOffsetX,
      noiseOffsetY: strongerNoise.noiseOffsetY,
      bands: Array((bands + other.bands).prefix(Self.maxBands)),
      sepia: max(sepia, other.sepia),
      brightness: brightness + other.brightness,
      invert: max(invert, other.invert),
      flash: max(flash, other.flash),
      vignette: strongerVignette.vignette,
      vignetteRadius: strongerVignette.vignetteRadius,
      zoom: zoom + other.zoom,
      offsetX: offsetX + other.offsetX,
      offsetY: offsetY + other.offsetY,
      mirrorX: max(mirrorX, other.mirrorX),
      mirrorY: max(mirrorY, other.mirrorY),
      tiles: max(tiles, other.tiles),
      waveAmplitude: strongerWave.waveAmplitude,
      wavePeriod: strongerWave.wavePeriod,
      wavePhase: strongerWave.wavePhase)
  }

  /// Reads the frame that starts at `offset` of a Dart-built table.
  static func from(_ values: [Double], offset: Int) -> VideoEffectFrame {
    let bandCount = min(max(Int(values[offset + 8]), 0), maxBands)
    return VideoEffectFrame(
      pixelSize: values[offset],
      rgbShift: values[offset + 1],
      scanlines: values[offset + 2],
      scanlinePeriod: values[offset + 3],
      noise: values[offset + 4],
      noiseCellSize: values[offset + 5],
      noiseOffsetX: Int(values[offset + 6]),
      noiseOffsetY: Int(values[offset + 7]),
      bands: (0..<bandCount).map { i in
        VideoEffectBand(
          top: values[offset + 9 + i * 3],
          bottom: values[offset + 10 + i * 3],
          shift: values[offset + 11 + i * 3])
      },
      sepia: values[offset + toneOffset],
      brightness: values[offset + toneOffset + 1],
      invert: values[offset + toneOffset + 2],
      flash: values[offset + toneOffset + 3],
      vignette: values[offset + toneOffset + 4],
      vignetteRadius: values[offset + toneOffset + 5],
      zoom: values[offset + geometryOffset],
      offsetX: values[offset + geometryOffset + 1],
      offsetY: values[offset + geometryOffset + 2],
      mirrorX: values[offset + geometryOffset + 3],
      mirrorY: values[offset + geometryOffset + 4],
      tiles: Int(values[offset + geometryOffset + 5].rounded()),
      waveAmplitude: values[offset + geometryOffset + 6],
      wavePeriod: values[offset + geometryOffset + 7],
      wavePhase: values[offset + geometryOffset + 8])
  }
}

/// One video effect: a looping table of `VideoEffectFrame`s, played back at
/// `frameRate` from `startUs` until `endUs` (exclusive).
///
/// Mirrors the Dart `VideoEffect`, whose `frameAt` picks the same frame for the
/// same time, so a preview and this render agree.
public struct VideoEffectConfig: Sendable {
  let startUs: Int64?
  let endUs: Int64?
  let frameRate: Int
  let frames: [VideoEffectFrame]

  /// The frame at `timeUs` on the composition timeline, or nil when inactive.
  func frame(atUs timeUs: Int64) -> VideoEffectFrame? {
    guard !frames.isEmpty else { return nil }
    if let startUs = startUs, timeUs < startUs { return nil }
    if let endUs = endUs, timeUs >= endUs { return nil }
    let localUs = max(0, timeUs - (startUs ?? 0))
    let bucket = localUs * Int64(frameRate) / 1_000_000
    return frames[Int(bucket % Int64(frames.count))]
  }

  /// The combined frame of every effect active at `timeUs`.
  static func resolve(_ effects: [VideoEffectConfig], atUs timeUs: Int64) -> VideoEffectFrame {
    var frame = VideoEffectFrame.none
    for effect in effects {
      guard let next = effect.frame(atUs: timeUs) else { continue }
      frame = frame.merged(with: next)
    }
    return frame
  }

  /// Builds an effect from the values of a Dart-built table, or nil when the
  /// table does not have the expected layout.
  static func from(
    values: [Double], stride: Int, frameRate: Int, startUs: Int64?, endUs: Int64?
  ) -> VideoEffectConfig? {
    guard stride == VideoEffectFrame.stride else { return nil }
    let count = values.count / stride
    guard count > 0 else { return nil }
    return VideoEffectConfig(
      startUs: startUs,
      endUs: endUs,
      frameRate: max(1, frameRate),
      frames: (0..<count).map { VideoEffectFrame.from(values, offset: $0 * stride) })
  }
}
