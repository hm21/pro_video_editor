import CoreImage
import Foundation
import Metal

// MARK: - The shared keying formula
//
// This is the single spec every renderer implements. Android runs it in
// `ChromaKeyEffect.kt`'s fragment shader, the Flutter preview in its own
// fragment shader, and Apple in the Metal compute kernel below
// (`ChromaKeyKernel`). The Kotlin and Swift unit tests assert the same golden
// tables against both, so a drift in either implementation fails fast.
//
// All values are gamma-encoded, non-color-managed RGB in 0...1 — the compositor
// runs with `workingColorSpace: NSNull()`, so these are exactly the numbers the
// decoder produced, which is what keeps the two platforms in step.
//
// The key distance of one pixel:
//
//   Y  =  0.299·r + 0.587·g + 0.114·b
//   Cb = -0.168736·r - 0.331264·g + 0.5·b
//   Cr =  0.5·r - 0.418688·g - 0.081312·b
//
//   w = 1 - smoothstep(0.04, 0.10, |(Cb_key, Cr_key)|)
//   d = |(Cb - Cb_key, Cr - Cr_key, w·(Y - Y_key))|
//
// The matte is not taken from one pixel alone. Video stores color at half the
// resolution of brightness, so a per-pixel key steps along an edge and flickers
// with compression noise. `d` is evaluated at the 3×3 neighbourhood of the
// output pixel, clamped to the frame edge, and the nine are averaged with
// binomial weights:
//
//   d     = (4·C + 2·(N + S + E + W) + (NE + NW + SE + SW)) / 16
//   alpha = smoothstep(similarity, similarity + smoothness, d)
//
// The average smooths those steps (see `chromaKeyNeighbourhoodDistance`). There
// is deliberately no choke toward the smallest distance: it removes a subject
// detail one pixel wide, such as a strand of hair, exactly as it removes the
// fringe. A uniform neighbourhood gives back its own `d`, so a flat area keys
// exactly as a single pixel would and `chromaKeyed(r:g:b:_:)` still describes
// it.
//
// For a saturated key `w` is 0 and the distance lives in the Cb/Cr chroma plane,
// which is a position rather than a pure hue: Cb and Cr scale with brightness,
// so a dimly lit patch of the screen sits closer to neutral and further from
// the key point. The default `similarity` of 0.20 covers roughly 40%-100% of
// the screen's reference brightness. Same behaviour as FFmpeg's `chromakey` and
// OBS. A neutral key has no chroma to tell white from black, so `w` rises to 1
// and brightness counts too (see `lumaWeightOf`).
//
// Spill suppression reads the centre pixel alone. It removes the chroma
// component pointing toward the key hue, leaving Y untouched so a despilled
// pixel never darkens. Its strength is `spill·(1 - w)`: a neutral key has no
// hue to pull out, and the faint tint a camera records on a white wall would
// otherwise desaturate the subject.

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

/// Below this key chroma magnitude, brightness counts fully in the matte.
let lumaWeightFullBelow = 0.04

/// Above this key chroma magnitude, brightness does not count at all.
let lumaWeightNoneAbove = 0.10

/// How much the brightness difference counts toward the matte distance, for a
/// key at chroma `(cb, cr)`.
///
/// A saturated key gets `0` and keys on chroma alone, so a shadow on the screen
/// stays under the key. A neutral key gets `1`: every neutral shares the chroma
/// origin, so without brightness a white key would also remove black. Mirrors
/// Kotlin's `ChromaKeyMath.lumaWeight`.
func lumaWeightOf(cb: Double, cr: Double) -> Double {
  return 1 - smoothstep(
    lumaWeightFullBelow, lumaWeightNoneAbove, (cb * cb + cr * cr).squareRoot())
}

/// The key distance of one pixel: chroma, plus brightness weighted by how
/// neutral the key is. Mirrors Kotlin's `ChromaKeyMath.distance`.
func chromaKeyDistance(r: Double, g: Double, b: Double, _ config: ChromaKeyConfig) -> Double {
  let chroma = chromaOf(r: r, g: g, b: b)
  let y = lumaOf(r: r, g: g, b: b)
  let key = config.keyChroma

  let dCb = chroma.cb - key.cb
  let dCr = chroma.cr - key.cr
  let dY = (y - config.keyLuma) * config.lumaWeight
  return (dCb * dCb + dCr * dCr + dY * dY).squareRoot()
}

/// Combines the key distances of a pixel's 3×3 neighbourhood, given row-major
/// (NW, N, NE, W, C, E, SW, S, SE), into the distance the matte is ramped on.
///
/// The weights are binomial, which smooths the steps half-resolution color
/// leaves along an edge. A uniform neighbourhood returns its own distance, so a
/// flat area keys exactly as a single pixel would. `ChromaKeyKernel` clamps the
/// neighbourhood to the frame edge. Mirrors Kotlin's
/// `ChromaKeyMath.neighbourhoodDistance`.
func chromaKeyNeighbourhoodDistance(_ taps: [Double]) -> Double {
  precondition(taps.count == 9, "Expected 9 taps, got \(taps.count)")
  let centre = 4 * taps[4]
  let edges = 2 * (taps[1] + taps[3] + taps[5] + taps[7])
  let corners = taps[0] + taps[2] + taps[6] + taps[8]
  return (centre + edges + corners) / 16
}

/// The matte alpha for a key distance, ramped by smoothstep from `similarity`
/// over `smoothness`. Mirrors Kotlin's `ChromaKeyMath.matte`.
func chromaKeyMatte(distance: Double, _ config: ChromaKeyConfig) -> Double {
  // max() keeps a zero-width ramp from dividing by zero; smoothstep already
  // guards it, but this also matches the shaders' `max(smoothness, 1e-4)`.
  return smoothstep(
    config.similarity,
    config.similarity + max(config.smoothness, 1e-4),
    distance
  )
}

/// Evaluates the chroma key for one pixel inside an area of its own color.
///
/// `ChromaKeyKernel` ramps the matte on the distance of nine pixels instead
/// (see `chromaKeyNeighbourhoodDistance`); over a flat area the two agree. The
/// despilled color is the kernel's exactly, since despill reads the centre
/// pixel alone.
///
/// Returns the despilled color together with the matte alpha, both **straight**
/// (not premultiplied) — the kernel premultiplies afterwards, as Core Image
/// expects.
func chromaKeyed(r: Double, g: Double, b: Double, _ config: ChromaKeyConfig)
  -> (r: Double, g: Double, b: Double, a: Double)
{
  let chroma = chromaOf(r: r, g: g, b: b)
  let y = lumaOf(r: r, g: g, b: b)
  let alpha = chromaKeyMatte(distance: chromaKeyDistance(r: r, g: g, b: b, config), config)

  // Spill suppression. `projection` is how far the pixel leans toward the key
  // hue; only pixels leaning toward it (> 0) are touched, so a complementary
  // color is never desaturated. The strength fades out with the luma weight,
  // so a neutral key does not despill at all. Mirrors Kotlin's
  // `ChromaKeyConfig.effectiveSpill`.
  let spill = config.spill * (1 - config.lumaWeight)
  let direction = config.keyDirection
  let projection = chroma.cb * direction.cb + chroma.cr * direction.cr
  guard spill > 0, projection > 0 else {
    return (r, g, b, alpha)
  }

  let cb = chroma.cb - direction.cb * projection * spill
  let cr = chroma.cr - direction.cr * projection * spill

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
/// - Note: The actual keying happens per frame in the compositor, which runs
///         `ChromaKeyKernel` on the frame and composites its background.
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

// MARK: - Metal kernel

/// Removes `config`'s key from `image` with `ChromaKeyKernel`.
///
/// The output is **premultiplied**, Core Image's convention: a fully removed
/// pixel is `(0, 0, 0, 0)`, not `(rgb, 0)`, or compositing would bring the
/// screen color back in along the soft edge. Android's shader writes straight
/// alpha instead, per Media3's convention — do not align the two.
///
/// The frame is clamped to its edge before the kernel reads it, so a border
/// pixel's neighbourhood repeats the border, as on Android.
func applyChromaKeyKernel(to image: CIImage, _ config: ChromaKeyConfig) -> CIImage {
  let extent = image.extent
  guard !extent.isEmpty, !extent.isInfinite else { return image }
  do {
    return try ChromaKeyKernel.apply(
      withExtent: extent,
      inputs: [image.clampedToExtent()],
      arguments: [ChromaKeyKernel.parametersKey: ChromaKeyKernel.parameters(for: config)]
    ).cropped(to: extent)
  } catch {
    PluginLog.print("[\(Tags.render)] ❌ Chroma key kernel failed: \(error)")
    return image
  }
}

/// Runs the shared keying formula on the GPU, one thread per output pixel.
///
/// A color cube cannot read a pixel's neighbours, which the matte needs, so the
/// key is a Metal compute shader instead. It is compiled from source at runtime
/// (`chromaKeyKernelSource`), which works on every Metal device without a
/// `.metal` file in the build. Evaluating the formula per pixel also keeps the
/// export identical to the preview at a small smoothness, where the 33³ cube
/// this replaces quantized the ramp.
final class ChromaKeyKernel: CIImageProcessorKernel {
  /// The `arguments` key under which `parameters(for:)` travels.
  static let parametersKey = "parameters"

  /// The shader's `p[]`, in its order.
  static func parameters(for config: ChromaKeyConfig) -> [NSNumber] {
    let key = config.keyChroma
    let direction = config.keyDirection
    let lumaWeight = config.lumaWeight
    return [
      key.cb, key.cr, config.keyLuma, lumaWeight,
      direction.cb, direction.cr,
      config.similarity, config.smoothness,
      config.spill * (1 - lumaWeight),
    ].map { NSNumber(value: $0) }
  }

  /// The kernel reads one pixel around each output pixel.
  override class func roi(
    forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect
  ) -> CGRect {
    return outputRect.insetBy(dx: -1, dy: -1)
  }

  // Half floats: 32-bit float textures are not filterable on every Apple GPU,
  // and 16 bits keep far more precision than the 8-bit frames being keyed.
  override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
  override class var outputFormat: CIFormat { .RGBAh }

  override class func process(
    with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
    output: CIImageProcessorOutput
  ) throws {
    guard let input = inputs?.first,
      let source = input.metalTexture,
      let destination = output.metalTexture,
      let commandBuffer = output.metalCommandBuffer
    else {
      throw ChromaKeyKernelError("needs a Metal-backed CIContext")
    }
    guard let parameters = arguments?[parametersKey] as? [NSNumber],
      parameters.count == parameterCount
    else {
      throw ChromaKeyKernelError("missing parameters")
    }
    let pipeline = try ChromaKeyPipelines.shared.pipeline(for: commandBuffer.device)
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw ChromaKeyKernelError("no compute encoder")
    }

    let values = parameters.map { $0.floatValue }
    // Where output texel (0, 0) sits in the input texture. Core Image's y axis
    // points up, but a texture's first row is the top of its region, so the
    // rows line up at the regions' top edges.
    let offset: [Int32] = [
      Int32((output.region.minX - input.region.minX).rounded()),
      Int32((input.region.maxY - output.region.maxY).rounded()),
    ]

    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(source, index: 0)
    encoder.setTexture(destination, index: 1)
    values.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
    offset.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }

    // Whole threadgroups, with a bounds check in the shader: dispatching an
    // exact grid needs non-uniform threadgroups, which A9 and A10 lack.
    let groupWidth = pipeline.threadExecutionWidth
    let groupHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / groupWidth)
    encoder.dispatchThreadgroups(
      MTLSize(
        width: (destination.width + groupWidth - 1) / groupWidth,
        height: (destination.height + groupHeight - 1) / groupHeight,
        depth: 1),
      threadsPerThreadgroup: MTLSize(width: groupWidth, height: groupHeight, depth: 1))
    encoder.endEncoding()
  }

  /// How many values `parameters(for:)` returns.
  private static let parameterCount = 9
}

/// Why `ChromaKeyKernel` could not run.
struct ChromaKeyKernelError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = "Chroma key kernel: \(description)"
  }
}

/// `ChromaKeyKernel`'s compiled pipeline, one per GPU.
///
/// Compiling takes a while, so it happens once per device; the compositor
/// renders frames concurrently, hence the lock.
private final class ChromaKeyPipelines: @unchecked Sendable {
  static let shared = ChromaKeyPipelines()

  private let lock = NSLock()
  private var pipelines: [UInt64: MTLComputePipelineState] = [:]

  func pipeline(for device: MTLDevice) throws -> MTLComputePipelineState {
    lock.lock()
    defer { lock.unlock() }
    if let pipeline = pipelines[device.registryID] { return pipeline }

    let library = try device.makeLibrary(source: chromaKeyKernelSource, options: nil)
    guard let function = library.makeFunction(name: "chromaKey") else {
      throw ChromaKeyKernelError("chromaKey missing from the compiled library")
    }
    let pipeline = try device.makeComputePipelineState(function: function)
    pipelines[device.registryID] = pipeline
    return pipeline
  }
}

/// The shared keying formula as a Metal compute shader; see the comment at the
/// top of this file. `p` is `ChromaKeyKernel.parameters(for:)`, `offset` where
/// output texel (0, 0) sits in `source`. Colors arrive premultiplied, are keyed
/// straight, and leave premultiplied.
private let chromaKeyKernelSource = """
  #include <metal_stdlib>
  using namespace metal;

  // p: keyCb, keyCr, keyLuma, lumaWeight, directionCb, directionCr,
  //    similarity, smoothness, spill (already faded by the luma weight).

  static float3 straightColor(float4 c) {
    return c.a > 0.0 ? c.rgb / c.a : float3(0.0);
  }

  static float2 chromaOf(float3 c) {
    return float2(
        dot(c, float3(-0.168736, -0.331264, 0.5)),
        dot(c, float3(0.5, -0.418688, -0.081312)));
  }

  static float lumaOf(float3 c) {
    return dot(c, float3(0.299, 0.587, 0.114));
  }

  static float keyDistance(float3 c, constant float *p) {
    return length(float3(chromaOf(c) - float2(p[0], p[1]), (lumaOf(c) - p[2]) * p[3]));
  }

  kernel void chromaKey(
      texture2d<float, access::read> source [[texture(0)]],
      texture2d<float, access::write> destination [[texture(1)]],
      constant float *p [[buffer(0)]],
      constant int2 &offset [[buffer(1)]],
      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
      return;
    }
    int2 last = int2(source.get_width(), source.get_height()) - 1;
    int2 centre = int2(gid) + offset;

    // Row-major NW, N, NE, W, C, E, SW, S, SE. Core Image hands over the frame
    // clamped to its edge, so the clamp here only guards the texture bounds.
    float taps[9];
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        uint2 at = uint2(clamp(centre + int2(dx, dy), int2(0), last));
        taps[(dy + 1) * 3 + dx + 1] = keyDistance(straightColor(source.read(at)), p);
      }
    }
    float d = (4.0 * taps[4] + 2.0 * (taps[1] + taps[3] + taps[5] + taps[7])
        + taps[0] + taps[2] + taps[6] + taps[8]) / 16.0;
    float matte = smoothstep(p[6], p[6] + max(p[7], 1e-4), d);

    // Despill reads the centre pixel alone.
    float4 src = source.read(uint2(clamp(centre, int2(0), last)));
    float3 rgb = straightColor(src);
    float2 direction = float2(p[4], p[5]);
    float2 cbcr = chromaOf(rgb);
    float projection = dot(cbcr, direction);
    if (p[8] > 0.0 && projection > 0.0) {
      float y = lumaOf(rgb);
      cbcr -= direction * projection * p[8];
      rgb = clamp(
          float3(
              y + 1.402 * cbcr.y,
              y - 0.344136 * cbcr.x - 0.714136 * cbcr.y,
              y + 1.772 * cbcr.x),
          0.0, 1.0);
    }

    float alpha = matte * src.a;
    destination.write(float4(rgb * alpha, alpha), gid);
  }
  """
