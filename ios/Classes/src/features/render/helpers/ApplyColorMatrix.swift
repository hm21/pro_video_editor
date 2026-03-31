import AVFoundation
import CoreImage

/// Applies color grading using color filter configurations with optional time ranges.
///
/// Color filters contain 4x5 transformation matrices (R, G, B, A + offset).
/// Filters without time ranges apply to the entire video, while timed filters
/// are evaluated per-frame by the video compositor.
///
/// - Parameters:
///   - config: Video compositor configuration to modify.
///   - filters: Array of color filter configurations with optional time ranges.
///
/// - Note: The filters are stored in the compositor config and processed per-frame
///         to support time-based color grading.
func applyColorMatrix(
    config: inout VideoCompositorConfig,
    filters: [ColorFilterConfig]
) {
    guard !filters.isEmpty else {
        return
    }

    config.colorFilterConfigs = filters

    let globalCount = filters.filter { $0.startUs == -1 && $0.endUs == -1 }.count
    let timedCount = filters.count - globalCount
    print(
        "[\(Tags.render)] 🎨 Applying color grading: \(filters.count) filter(s) (\(globalCount) global, \(timedCount) timed)"
    )
}

// MARK: - Matrix Combination Logic

func multiplyColorMatrices(_ m1: [Double], _ m2: [Double]) -> [Double] {
    guard m1.count == 20, m2.count == 20 else {
        print("Invalid matrix dimensions for multiplication")
        return m1
    }

    var result = [Double](repeating: 0.0, count: 20)
    for i in 0...3 {
        for j in 0...4 {
            result[i * 5 + j] =
                m1[i * 5 + 0] * m2[0 + j] + m1[i * 5 + 1] * m2[5 + j] + m1[i * 5 + 2] * m2[10 + j]
                + m1[i * 5 + 3] * m2[15 + j] + (j == 4 ? m1[i * 5 + 4] : 0.0)
        }
    }
    return result
}

func combineColorMatrices(_ matrices: [[Double]]) -> [Double] {
    guard !matrices.isEmpty else { return [] }
    return matrices.dropFirst().reduce(matrices.first!) { acc, next in
        multiplyColorMatrices(next, acc)
    }
}

func generateLUTData(from matrix: [Double], size: Int) -> Data? {
    let floatCount = size * size * size * 4
    var cubeData = [Float](repeating: 0, count: floatCount)

    var offset = 0
    for b in 0..<size {
        for g in 0..<size {
            for r in 0..<size {
                let rf = Double(r) / Double(size - 1)
                let gf = Double(g) / Double(size - 1)
                let bf = Double(b) / Double(size - 1)

                let rr =
                    (matrix[0] * rf + matrix[1] * gf + matrix[2] * bf + matrix[3])
                    + (matrix[4] / 255.0)
                let gg =
                    (matrix[5] * rf + matrix[6] * gf + matrix[7] * bf + matrix[8])
                    + (matrix[9] / 255.0)
                let bb =
                    (matrix[10] * rf + matrix[11] * gf + matrix[12] * bf + matrix[13])
                    + (matrix[14] / 255.0)

                let rInt = Int((rr.clamped01()) * 255.0 + 0.5)
                let gInt = Int((gg.clamped01()) * 255.0 + 0.5)
                let bInt = Int((bb.clamped01()) * 255.0 + 0.5)

                cubeData[offset] = Float(rInt) / 255.0
                cubeData[offset + 1] = Float(gInt) / 255.0
                cubeData[offset + 2] = Float(bInt) / 255.0
                cubeData[offset + 3] = 1.0
                offset += 4
            }
        }
    }
    return Data(bytes: cubeData, count: cubeData.count * MemoryLayout<Float>.size)
}

extension Double {
    fileprivate func clamped01() -> Double {
        return min(max(self, 0.0), 1.0)
    }
}
