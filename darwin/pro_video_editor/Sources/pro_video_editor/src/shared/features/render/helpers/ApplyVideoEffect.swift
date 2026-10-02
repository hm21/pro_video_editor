import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Stores the render's video effects (glitch, VHS, old film, …) on the
/// compositor config. The compositor picks each frame's operations by its
/// composition time and applies them right before the color filters.
func applyVideoEffects(config: inout VideoCompositorConfig, effects: [VideoEffectConfig]) {
  config.videoEffects = effects
}

/// Rounds a fraction of `size` to whole pixels: `floor(fraction * size + 0.5)`.
func videoEffectPixels(_ fraction: Double, _ size: Int) -> Int {
  Int((fraction * Double(size) + 0.5).rounded(.down))
}

/// The noise value, in `[0, 1)`, of a cell of the 128x128 noise tile.
func videoEffectNoise(u: Int, v: Int) -> Double {
  var a = (u * 37 + v * 101 + 13) % 251
  a = (a * a + u * 7 + 17) % 251
  a = (a * a + v * 3 + 29) % 251
  return Double(a) / 251
}

/// Edge length of the repeating noise tile, in cells.
let videoEffectNoiseTileSize = 128

/// The noise tile as an image, one pixel per cell, built once.
///
/// Stored as floats so every value is exactly the one the shaders compute.
/// Rows are laid out for the top-origin space `applyVideoEffect` works in:
/// the pixel at Core Image `y == v` holds row `v` of the tile.
private let videoEffectNoiseTile: CIImage = {
  let size = videoEffectNoiseTileSize
  var values = [Float](repeating: 1, count: size * size * 4)
  for row in 0..<size {
    // A bitmap's first row is the image's top, at Core Image y == size - 1.
    let v = size - 1 - row
    for u in 0..<size {
      let n = Float(videoEffectNoise(u: u, v: v))
      let i = (row * size + u) * 4
      values[i] = n
      values[i + 1] = n
      values[i + 2] = n
    }
  }
  let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
  return CIImage(
    bitmapData: data,
    bytesPerRow: size * 4 * MemoryLayout<Float>.size,
    size: CGSize(width: size, height: size),
    format: .RGBAf,
    colorSpace: nil)
}()

/// Applies `frame` to `image`, pixel for pixel as specified by Kotlin's
/// `VideoEffectMath` and implemented by the Android and Flutter shaders.
///
/// Built from stock Core Image filters only, so it runs on every device the
/// plugin supports: a custom kernel would need Metal dynamic libraries, which
/// older iPhones lack. After the geometry, every step moves whole pixels —
/// sizes are rounded first, and resampling happens only at pixel centers — so
/// nothing is interpolated. The geometry interpolates, with the GPU's bilinear
/// filtering, which can land one step away from the spec's exact arithmetic.
///
/// The spec counts rows from the top, so the frame is flipped into a top-origin
/// space for the duration and flipped back at the end.
func applyVideoEffect(to image: CIImage, _ frame: VideoEffectFrame) -> CIImage {
  guard !frame.isIdentity else { return image }
  let extent = image.extent
  let width = Int(extent.width.rounded())
  let height = Int(extent.height.rounded())
  guard width > 0, height > 0, !extent.isInfinite else { return image }

  let rect = CGRect(x: 0, y: 0, width: width, height: height)
  let toTopOrigin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
    .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.height))
  // The geometry reads the source bilinearly and ends in nearest sampling
  // itself; without it, the source is read nearest, so a frame whose extent
  // is not on whole pixels is still copied pixel for pixel.
  let hasGeometry = frame.hasTransform || frame.tiles >= 2 || frame.hasWave
  var result = (hasGeometry ? image : image.samplingNearest())
    .transformed(by: toTopOrigin).cropped(to: rect)
  result = applyingGeometry(result, frame, rect: rect).samplingNearest()

  let block = videoEffectPixels(frame.pixelSize, width)
  if block >= 2 {
    result = pixelated(result, block: block, rect: rect)
  }
  result = shiftingBands(result, frame, width: width, height: height, rect: rect)

  let split = videoEffectPixels(frame.rgbShift, width)
  if split != 0 {
    result = splittingChannels(result, by: split, rect: rect)
  }

  if frame.scanlines > 0 {
    let period = max(2, videoEffectPixels(frame.scanlinePeriod, height))
    result = darkeningScanlines(result, amount: frame.scanlines, period: period, rect: rect)
  }

  if frame.noise > 0 {
    let cell = max(1, videoEffectPixels(frame.noiseCellSize, height))
    result = addingNoise(result, frame, cell: cell, rect: rect)
  }

  if frame.sepia > 0 || frame.brightness != 0 || frame.invert != 0 || frame.flash != 0 {
    result = clamped(toning(clamped(result), frame, rect: rect))
  }

  if frame.vignette > 0 {
    result = vignetting(result, frame, rect: rect)
  }

  if frame.glow > 0 {
    result = glowing(clamped(result), frame, rect: rect)
  }

  return result.transformed(by: toTopOrigin.inverted()).cropped(to: extent)
}

/// The three geometry stages: bend the rows along a wave, zoom, move and
/// mirror the picture, and repeat it in a 2×2 grid.
///
/// Each stage that runs ends in an intermediate image. Core Image would
/// otherwise fold one stage's transforms into the next stage's sampling, and
/// into the nearest sampling of the steps after the geometry, which reads the
/// source once with other weights than the spec's stage-by-stage filtering.
/// That holds for the mirror after the zoom too, although it only moves whole
/// pixels: without the zoom's intermediate the two together land several
/// steps away from the spec.
///
/// The intermediates are not cached: every video frame is a new picture, so
/// none would ever be reused, and they would only crowd out what is.
private func applyingGeometry(_ image: CIImage, _ frame: VideoEffectFrame, rect: CGRect)
  -> CIImage
{
  var result = image
  if frame.hasWave {
    result = waving(result, frame, rect: rect).insertingIntermediate(cache: false)
  }
  let zoom = max(frame.zoom, 0)
  if zoom > 0 || frame.offsetX != 0 || frame.offsetY != 0 {
    let w = rect.width
    let h = rect.height
    let move = CGAffineTransform(translationX: -w / 2, y: -h / 2)
      .concatenating(CGAffineTransform(scaleX: 1 + zoom, y: 1 + zoom))
      .concatenating(
        CGAffineTransform(
          translationX: w / 2 + CGFloat(frame.offsetX) * w,
          y: h / 2 + CGFloat(frame.offsetY) * h))
    result = result.clampedToExtent().transformed(by: move).cropped(to: rect)
      .insertingIntermediate(cache: false)
  }
  if frame.mirrorX > 0 || frame.mirrorY > 0 {
    result = mirroring(result, frame, rect: rect).insertingIntermediate(cache: false)
  }
  if frame.tiles >= 2 {
    result = tiling(result, rect: rect).insertingIntermediate(cache: false)
  }
  return result
}

/// The right `m` columns show the columns left of them mirrored, and the
/// bottom rows the rows above them. Mirroring about a whole-pixel axis maps
/// pixel centers onto pixel centers, so nothing is resampled.
private func mirroring(_ image: CIImage, _ frame: VideoEffectFrame, rect: CGRect) -> CIImage {
  let width = Int(rect.width)
  let height = Int(rect.height)
  var result = image.clampedToExtent()
  if frame.mirrorX > 0 {
    let axis = CGFloat(width - min(videoEffectPixels(frame.mirrorX, width), width / 2))
    let mirrored = result.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * axis, ty: 0))
      .cropped(to: CGRect(x: axis, y: 0, width: rect.width - axis, height: rect.height))
    result = mirrored.composited(
      over: result.cropped(to: CGRect(x: 0, y: 0, width: axis, height: rect.height))
    ).cropped(to: rect).clampedToExtent()
  }
  if frame.mirrorY > 0 {
    let axis = CGFloat(height - min(videoEffectPixels(frame.mirrorY, height), height / 2))
    let mirrored = result.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * axis))
      .cropped(to: CGRect(x: 0, y: axis, width: rect.width, height: rect.height - axis))
    result = mirrored.composited(
      over: result.cropped(to: CGRect(x: 0, y: 0, width: rect.width, height: axis)))
  }
  return result.cropped(to: rect)
}

/// The picture at half its size, four times. Each copy is cropped to the
/// pixels whose centers lie in its quarter of the frame, so frames of odd
/// sizes split the way the spec's `(p * 2) % size` does.
private func tiling(_ image: CIImage, rect: CGRect) -> CIImage {
  let tiles = VideoEffectFrame.maxTiles
  let half = image.clampedToExtent().transformed(
    by: CGAffineTransform(scaleX: 1 / CGFloat(tiles), y: 1 / CGFloat(tiles)))
  func edges(_ size: Int) -> [Int] {
    (0...tiles).map { k in Int((Double(k * size) / Double(tiles) - 0.5).rounded(.up)) }
  }
  let xs = edges(Int(rect.width))
  let ys = edges(Int(rect.height))
  var result = CIImage.empty()
  for row in 0..<tiles {
    for column in 0..<tiles {
      let cell = CGRect(
        x: xs[column], y: ys[row], width: xs[column + 1] - xs[column],
        height: ys[row + 1] - ys[row])
      let copy = half.transformed(
        by: CGAffineTransform(
          translationX: CGFloat(column) * rect.width / CGFloat(tiles),
          y: CGFloat(row) * rect.height / CGFloat(tiles)))
      result = copy.cropped(to: cell).composited(over: result)
    }
  }
  return result.cropped(to: rect)
}

/// Bends the rows sideways along the wave of `frame`.
///
/// The spec draws the wave with `waveSegments` straight segments per wave, so
/// within a segment each row moves by a straight-line function of its height:
/// a shear. Every segment is the picture sheared by its line and cropped to
/// the rows whose centers it covers; Core Image's bilinear filtering then reads
/// each row exactly where the spec does.
///
/// Each row's segment is computed the way the spec computes it. Segment
/// boundaries worked out per segment instead can round apart, which leaves a
/// row in no segment, and empty.
private func waving(_ image: CIImage, _ frame: VideoEffectFrame, rect: CGRect) -> CIImage {
  let width = Double(rect.width)
  let height = Int(rect.height)
  let segments = Double(VideoEffectFrame.waveSegments)
  let period = max(frame.wavePeriod, VideoEffectFrame.minWavePeriod) * Double(height)
  let step = period / segments
  func knot(_ k: Int) -> Double {
    frame.waveAmplitude * width * sin(2 * Double.pi * Double(k) / segments)
  }
  func segment(_ row: Int) -> Int {
    Int((((Double(row) + 0.5) / period + frame.wavePhase) * segments).rounded(.down))
  }
  let clamped = image.clampedToExtent()
  var result = CIImage.empty()
  var firstRow = 0
  while firstRow < height {
    let k = segment(firstRow)
    var endRow = firstRow + 1
    while endRow < height && segment(endRow) == k { endRow += 1 }
    // Segment k starts at the row center `top`.
    let top = (Double(k) / segments - frame.wavePhase) * period
    let slope = (knot(k + 1) - knot(k)) / step
    let shear = CGAffineTransform(
      a: 1, b: 0, c: CGFloat(slope), d: 1, tx: CGFloat(knot(k) - slope * top), ty: 0)
    result = clamped.transformed(by: shear)
      .cropped(to: CGRect(x: 0, y: firstRow, width: Int(rect.width), height: endRow - firstRow))
      .composited(over: result)
    firstRow = endRow
  }
  return result.cropped(to: rect)
}

/// Blocks of `block` pixels from the top-left corner, each filled with the
/// pixel at `blockStart + block / 2`.
///
/// `CIPixellate` samples each block at `center + blockStart + block / 2`. For
/// an even block that point is a pixel corner, so the grid is moved by half a
/// pixel: pixel centers stay in the same blocks, and every sample lands on the
/// center of exactly the pixel the spec names.
private func pixelated(_ image: CIImage, block: Int, rect: CGRect) -> CIImage {
  let filter = CIFilter.pixellate()
  filter.inputImage = image.clampedToExtent().samplingNearest()
  let offset: CGFloat = block % 2 == 0 ? 0.5 : 0
  filter.center = CGPoint(x: offset, y: offset)
  filter.scale = Float(block)
  return (filter.outputImage ?? image).cropped(to: rect)
}

/// Rows covered by a band take the image shifted right by the band's shift.
/// Where bands overlap, the first one wins, so they are laid on in reverse.
private func shiftingBands(
  _ image: CIImage, _ frame: VideoEffectFrame, width: Int, height: Int, rect: CGRect
) -> CIImage {
  let bands = frame.bands.prefix(VideoEffectFrame.maxBands)
  guard !bands.isEmpty else { return image }
  let clamped = image.clampedToExtent()
  var result = image
  for band in bands.reversed() {
    let top = videoEffectPixels(band.top, height)
    let bottom = videoEffectPixels(band.bottom, height)
    let rows = CGRect(x: 0, y: CGFloat(top), width: rect.width, height: CGFloat(bottom - top))
      .intersection(rect)
    guard !rows.isNull, rows.height > 0 else { continue }
    let shift = CGFloat(videoEffectPixels(band.shift, width))
    result = clamped.transformed(by: CGAffineTransform(translationX: shift, y: 0))
      .cropped(to: rows)
      .composited(over: result)
  }
  return result
}

/// Red read `split` pixels to the right, blue as far to the left, green in
/// place: each channel is isolated into an otherwise black, opaque image, and
/// the three are combined with a per-component maximum.
private func splittingChannels(_ image: CIImage, by split: Int, rect: CGRect) -> CIImage {
  let clamped = image.clampedToExtent()
  let d = CGFloat(split)
  let red = isolatingChannel(
    clamped.transformed(by: CGAffineTransform(translationX: -d, y: 0)), 0
  ).cropped(to: rect)
  let green = isolatingChannel(image, 1)
  let blue = isolatingChannel(
    clamped.transformed(by: CGAffineTransform(translationX: d, y: 0)), 2
  ).cropped(to: rect)
  return
    red
    .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: green])
    .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: blue])
    .cropped(to: rect)
}

/// Keeps one color channel and opaque alpha. Alpha stays 1 because
/// `CIColorMatrix` premultiplies its result, and a zero alpha would erase the
/// channel it was meant to keep.
private func isolatingChannel(_ image: CIImage, _ channel: Int) -> CIImage {
  let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
  return image.applyingFilter(
    "CIColorMatrix",
    parameters: [
      "inputRVector": channel == 0 ? CIVector(x: 1, y: 0, z: 0, w: 0) : zero,
      "inputGVector": channel == 1 ? CIVector(x: 0, y: 1, z: 0, w: 0) : zero,
      "inputBVector": channel == 2 ? CIVector(x: 0, y: 0, z: 1, w: 0) : zero,
      "inputAVector": zero,
      "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
    ])
}

/// Multiplies the rows where `(y % period) * 2 >= period` by `1 - amount`, via
/// a one-pixel-wide pattern of one period, tiled over the frame.
private func darkeningScanlines(
  _ image: CIImage, amount: Double, period: Int, rect: CGRect
) -> CIImage {
  let keep = CGFloat(1 - amount)
  let firstDark = (period + 1) / 2
  let bright = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: 1, height: period))
  let dark = CIImage(color: CIColor(red: keep, green: keep, blue: keep))
    .cropped(to: CGRect(x: 0, y: firstDark, width: 1, height: period - firstDark))
  let pattern = tiled(dark.composited(over: bright)).cropped(to: rect)
  return pattern.applyingFilter(
    "CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: image]
  ).cropped(to: rect)
}

/// Adds `(noise(u, v) - 0.5) * frame.noise` to red, green and blue.
///
/// The tile is scaled to the cell size with nearest sampling while it is
/// tiled, and moved by the frame's offset. A signed value cannot pass through `CIColorMatrix`
/// intact, so the positive and negative halves are split into two opaque
/// images and applied with an add and a subtract blend.
private func addingNoise(
  _ image: CIImage, _ frame: VideoEffectFrame, cell: Int, rect: CGRect
) -> CIImage {
  let c = CGFloat(cell)
  let tiling = CIFilter.affineTile()
  tiling.inputImage = videoEffectNoiseTile.samplingNearest()
  tiling.transform = CGAffineTransform(scaleX: c, y: c)
  let noise = (tiling.outputImage ?? videoEffectNoiseTile)
    .transformed(
      by: CGAffineTransform(
        translationX: -CGFloat(frame.noiseOffsetX) * c,
        y: -CGFloat(frame.noiseOffsetY) * c))
    .cropped(to: rect)

  let amount = CGFloat(frame.noise)
  let brighten = noiseHalf(noise, gain: amount, bias: -amount / 2)
  let darken = noiseHalf(noise, gain: -amount, bias: amount / 2)
  let brightened = brighten
    .applyingFilter("CILinearDodgeBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    .cropped(to: rect)
  // Subtracts the input from the background.
  return darken
    .applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: brightened])
    .cropped(to: rect)
}

/// `clamp(noise * gain + bias, 0, 1)` in every color channel, opaque.
private func noiseHalf(_ noise: CIImage, gain: CGFloat, bias: CGFloat) -> CIImage {
  noise
    .applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
      ]
    )
    .applyingFilter(
      "CIColorClamp",
      parameters: [
        "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
      ])
}

/// The sepia tone matrix, row by row: red, green and blue out of `(r, g, b)`.
private let videoEffectSepia: [[Double]] = [
  [0.393, 0.769, 0.189],
  [0.349, 0.686, 0.168],
  [0.272, 0.534, 0.131],
]

/// The tones of `frame` — sepia, brightness, invert and flash, in that order —
/// as one affine map `rgb * rows + bias`. The spec clamps nothing between
/// them, so they compose exactly.
func videoEffectTone(_ frame: VideoEffectFrame) -> (rows: [[Double]], bias: Double) {
  var rows: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
  if frame.sepia > 0 {
    let s = frame.sepia
    rows = (0..<3).map { i in (0..<3).map { j in rows[i][j] * (1 - s) + videoEffectSepia[i][j] * s } }
  }
  var bias = 0.0
  func scale(_ factor: Double, adding constant: Double) {
    rows = rows.map { $0.map { $0 * factor } }
    bias = bias * factor + constant
  }
  scale(1 + frame.brightness, adding: 0)
  scale(1 - 2 * frame.invert, adding: frame.invert)
  scale(1 - frame.flash, adding: frame.flash)
  return (rows, bias)
}

/// Applies the tones with a single `CIColorMatrix`, which does not clamp, so
/// a tone that overshoots 0..1 can still be brought back by a later one.
private func toning(_ image: CIImage, _ frame: VideoEffectFrame, rect: CGRect) -> CIImage {
  let (rows, bias) = videoEffectTone(frame)
  func row(_ i: Int) -> CIVector {
    CIVector(x: CGFloat(rows[i][0]), y: CGFloat(rows[i][1]), z: CGFloat(rows[i][2]), w: 0)
  }
  let b = CGFloat(bias)
  return image.applyingFilter(
    "CIColorMatrix",
    parameters: [
      "inputRVector": row(0),
      "inputGVector": row(1),
      "inputBVector": row(2),
      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0),
    ]
  ).cropped(to: rect)
}

/// Multiplies each pixel by `1 - vignette * t²`.
///
/// `CIRadialGradient` interpolates linearly between its two radii, so a
/// gradient from 0 at `radius * sqrt(2)` to 1 at `sqrt(2)`, stretched to half
/// the frame's width and height around its center, is exactly `t` at every
/// pixel center. Multiplied with itself it gives `t²`.
private func vignetting(_ image: CIImage, _ frame: VideoEffectFrame, rect: CGRect) -> CIImage {
  let radius = min(max(frame.vignetteRadius, 0), 0.99)
  let gradient = CIFilter.radialGradient()
  gradient.center = .zero
  gradient.radius0 = Float(radius * 2.0.squareRoot())
  gradient.radius1 = Float(2.0.squareRoot())
  gradient.color0 = CIColor(red: 0, green: 0, blue: 0)
  gradient.color1 = CIColor(red: 1, green: 1, blue: 1)
  let halfWidth = rect.width / 2
  let halfHeight = rect.height / 2
  let t = (gradient.outputImage ?? CIImage(color: .black))
    .transformed(
      by: CGAffineTransform(scaleX: halfWidth, y: halfHeight)
        .concatenating(CGAffineTransform(translationX: halfWidth, y: halfHeight))
    )
    .cropped(to: rect)
  let a = CGFloat(-frame.vignette)
  let factor = t
    .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: t])
    .applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1),
      ])
  return factor.applyingFilter(
    "CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: image]
  ).cropped(to: rect)
}

/// Lets the brightest areas glow: with the brightness
/// `l = 0.2126 r + 0.7152 g + 0.0722 b` and `k = clamp((l - t) / (1 - t), 0, 1)`,
/// `min(1, glow * k * c)` is blurred into a halo and screened over the picture,
/// `1 - (1 - c) * (1 - halo)`.
///
/// The blur is Core Image's own Gaussian with the spec's standard deviation.
/// Its kernel is not documented and differs from the spec's by a step or two,
/// which the spec allows for this one operation.
private func glowing(_ image: CIImage, _ frame: VideoEffectFrame, rect: CGRect) -> CIImage {
  let t = min(max(frame.glowThreshold, 0), 0.99)
  // k in every channel: the brightness, moved and stretched so the threshold
  // lands on 0 and full brightness on 1, then clamped.
  let gain = CGFloat(1 / (1 - t))
  let bias = CGFloat(-t / (1 - t))
  let luma = CIVector(x: 0.2126 * gain, y: 0.7152 * gain, z: 0.0722 * gain, w: 0)
  let k = image.applyingFilter(
    "CIColorMatrix",
    parameters: [
      "inputRVector": luma,
      "inputGVector": luma,
      "inputBVector": luma,
      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
      "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
    ]
  ).applyingFilter(
    "CIColorClamp",
    parameters: [
      "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
      "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
    ])
  let amount = CGFloat(frame.glow)
  let bright = k.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: image])
    .applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      ]
    ).applyingFilter(
      "CIColorClamp",
      parameters: [
        "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
      ])
  let sigma = frame.glowRadius * Double(rect.height)
  // The intermediate drops the nearest sampling the steps before set up, which
  // the blur would otherwise inherit and resample with.
  let halo =
    sigma < 0.5
    ? bright.cropped(to: rect)
    : bright.cropped(to: rect).insertingIntermediate().samplingLinear().clampedToExtent()
      .applyingGaussianBlur(sigma: sigma).cropped(to: rect)
  return clamped(
    halo.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
      .cropped(to: rect))
}

/// Clamps red, green and blue to 0..1, where the spec clamps between steps.
private func clamped(_ image: CIImage) -> CIImage {
  image.applyingFilter(
    "CIColorClamp",
    parameters: [
      "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
      "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
    ])
}

/// Repeats `image`'s extent across the whole plane, from its origin, one to
/// one.
private func tiled(_ image: CIImage) -> CIImage {
  let filter = CIFilter.affineTile()
  filter.inputImage = image
  filter.transform = .identity
  return filter.outputImage ?? image
}
