import CoreImage
import Foundation

// MARK: - The shared keying formula
//
// This is the single spec both platforms implement. Android runs it per pixel
// in `ChromaKeyEffect.kt`'s fragment shader; Apple bakes it into a color cube
// (see `generateChromaLUTData`) because Core Image has no custom kernel here.
// The Kotlin and Swift unit tests assert the same golden table against both, so
// a drift in either implementation fails fast.
//
// All values are gamma-encoded, non-color-managed RGB in 0...1 — the compositor
// runs with `workingColorSpace: NSNull()`, so these are exactly the numbers the
// decoder produced, which is what keeps the two platforms in step.
//
//   Y  =  0.299·r + 0.587·g + 0.114·b
//   Cb = -0.168736·r - 0.331264·g + 0.5·b
//   Cr =  0.5·r - 0.418688·g - 0.081312·b
//
//   d     = distance((Cb, Cr), (Cb_key, Cr_key))
//   alpha = smoothstep(similarity, similarity + smoothness, d)
//
// The distance lives in the Cb/Cr chroma plane, which is a position rather than
// a pure hue: Cb and Cr scale with brightness, so a dimly lit patch of the
// screen sits closer to neutral and further from the key point. The default
// `similarity` of 0.20 covers roughly 40%-100% of the screen's reference
// brightness. Same behaviour as FFmpeg's `chromakey` and OBS.
//
// Spill suppression removes the chroma component pointing toward the key hue,
// leaving Y untouched so a despilled pixel never darkens.

/// BT.601 chroma projection of a gamma-encoded RGB triple.
func chromaOf(r: Double, g: Double, b: Double) -> (cb: Double, cr: Double) {
  return (
    cb: -0.168736 * r - 0.331264 * g + 0.5 * b,
    cr: 0.5 * r - 0.418688 * g - 0.081312 * b
  )
}

/// BT.601 luma of a gamma-encoded RGB triple.
func lumaOf(r: Double, g: Double, b: Double) -> Double {
  return 0.299 * r + 0.587 * g + 0.114 * b
}

/// Hermite smoothstep, matching GLSL's `smoothstep`.
private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
  guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
  let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
  return t * t * (3 - 2 * t)
}

/// Evaluates the chroma key for one pixel.
///
/// Returns the despilled color together with the matte alpha, both **straight**
/// (not premultiplied) — the cube builder premultiplies afterwards, since that
/// is what `CIColorCube` requires.
func chromaKeyed(r: Double, g: Double, b: Double, _ config: ChromaKeyConfig)
  -> (r: Double, g: Double, b: Double, a: Double)
{
  let chroma = chromaOf(r: r, g: g, b: b)
  let key = config.keyChroma

  let dCb = chroma.cb - key.cb
  let dCr = chroma.cr - key.cr
  let distance = (dCb * dCb + dCr * dCr).squareRoot()

  // max() keeps a zero-width ramp from dividing by zero; smoothstep already
  // guards it, but this also matches the shader's `max(uSmoothness, 1e-4)`.
  let alpha = smoothstep(
    config.similarity,
    config.similarity + max(config.smoothness, 1e-4),
    distance
  )

  // Spill suppression. `projection` is how far the pixel leans toward the key
  // hue; only pixels leaning toward it (> 0) are touched, so a complementary
  // color is never desaturated.
  let direction = config.keyDirection
  let projection = chroma.cb * direction.cb + chroma.cr * direction.cr
  guard config.spill > 0, projection > 0 else {
    return (r, g, b, alpha)
  }

  let y = lumaOf(r: r, g: g, b: b)
  let cb = chroma.cb - direction.cb * projection * config.spill
  let cr = chroma.cr - direction.cr * projection * config.spill

  return (
    r: min(max(y + 1.402 * cr, 0), 1),
    g: min(max(y - 0.344136 * cb - 0.714136 * cr, 0), 1),
    b: min(max(y + 1.772 * cb, 0), 1),
    a: alpha
  )
}

// MARK: - Compositor wiring

/// A chroma-key window in composition time.
///
/// The single-track path resolves the key per clip, so each clip contributes
/// one window covering its own span of the timeline — the same shape as the
/// existing `FadeWindow`.
public struct ChromaKeyWindow: Sendable {
  /// Inclusive start of the window in composition microseconds.
  let startUs: Int64
  /// Exclusive end of the window in composition microseconds.
  let endUs: Int64
  let config: ChromaKeyConfig
}

/// Hands the per-clip chroma-key windows to the custom video compositor.
///
/// - Parameters:
///   - config: Video compositor configuration to modify.
///   - windows: One window per clip that carries a key; empty disables keying.
///
/// - Note: The actual keying happens per frame in the compositor, which builds
///         a color cube from the key and composites its background.
func applyChromaKey(
  config: inout VideoCompositorConfig,
  windows: [ChromaKeyWindow]
) {
  guard !windows.isEmpty else { return }

  config.chromaKeyWindows = windows

  PluginLog.print(
    "[\(Tags.render)] 🟩 Applying chroma key: \(windows.count) window(s)"
  )
}

// MARK: - Color cube

/// Builds a premultiplied RGBA color cube for the chroma key.
///
/// The whole key fits in a cube because both halves — the matte alpha and the
/// despilled color — are pure functions of the input RGB. This is what lets
/// Apple key without a custom `CIKernel` or any Metal.
///
/// Entries are **premultiplied**, which `CIColorCube` requires: a fully removed
/// pixel is `(0, 0, 0, 0)`, not `(rgb, 0)`, or Core Image would composite the
/// screen color back in along the soft edge. Android's shader writes straight
/// alpha instead, per Media3's convention — do not align the two.
///
/// - Parameters:
///   - chroma: The key to bake in.
///   - size: Cube dimension per axis. `CIColorCube` supports up to 64.
func generateChromaLUTData(
  chroma: ChromaKeyConfig,
  size: Int
) -> Data? {
  let floatCount = size * size * size * 4
  var cubeData = [Float](repeating: 0, count: floatCount)

  var offset = 0
  for b in 0..<size {
    for g in 0..<size {
      for r in 0..<size {
        let rf = Double(r) / Double(size - 1)
        let gf = Double(g) / Double(size - 1)
        let bf = Double(b) / Double(size - 1)

        let (kr, kg, kb, alpha) = chromaKeyed(r: rf, g: gf, b: bf, chroma)

        cubeData[offset] = Float(kr * alpha)
        cubeData[offset + 1] = Float(kg * alpha)
        cubeData[offset + 2] = Float(kb * alpha)
        cubeData[offset + 3] = Float(alpha)
        offset += 4
      }
    }
  }

  return Data(bytes: cubeData, count: cubeData.count * MemoryLayout<Float>.size)
}
