import AVFoundation
import CoreImage

/// Applies color grading using a 4x5 color matrix converted to a 3D LUT.
///
/// Color matrices are powerful tools for color correction and grading. Each matrix
/// is a 4x5 transformation matrix (R, G, B, A + offset). Multiple matrices are
/// combined by multiplication and then converted to a 3D lookup table for efficient
/// GPU-based color transformation during rendering.
///
/// - Parameters:
///   - config: Video compositor configuration to modify.
///   - matrixList: Array of 4x5 color matrices (20 elements each). Multiple matrices
///                 are combined through matrix multiplication.
///   - lutSize: Size of the 3D LUT cube (default 33x33x33 = 35,937 color samples).
///
/// - Note: The LUT is generated once and applied to every frame by the video compositor.
func applyColorMatrix(
    config: inout VideoCompositorConfig,
    matrixList: [[Double]],
    lutSize: Int = 33
) {
    guard !matrixList.isEmpty else {
        return
    }

    let combined = combineColorMatrices(matrixList)
    guard combined.count == 20 else {
        print(
            "[\(Tags.render)] ⚠️ Invalid color matrix: expected 20 elements, got \(combined.count) - skipping"
        )
        return
    }

    print(
        "[\(Tags.render)] 🎨 Applying color grading: \(matrixList.count) matrices combined into \(lutSize)x\(lutSize)x\(lutSize) LUT"
    )

    guard let data = generateLUTData(from: combined, size: lutSize) else {
        print("[\(Tags.render)] ❌ Failed to generate LUT data")
        return
    }

    config.lutData = data
    config.lutSize = lutSize
}

// MARK: - Matrix Combination Logic

private func multiplyColorMatrices(_ m1: [Double], _ m2: [Double]) -> [Double] {
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

private func combineColorMatrices(_ matrices: [[Double]]) -> [Double] {
    guard !matrices.isEmpty else { return [] }
    return matrices.dropFirst().reduce(matrices.first!) { acc, next in
        multiplyColorMatrices(next, acc)
    }
}

private func generateLUTData(from matrix: [Double], size: Int) -> Data? {
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
