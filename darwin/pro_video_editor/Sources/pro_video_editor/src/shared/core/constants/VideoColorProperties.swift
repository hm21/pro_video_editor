import AVFoundation

/// Color properties for the H.264 encodes the plugin writes itself with
/// `AVAssetWriter`.
internal enum VideoColorProperties {

  /// BT.709 primaries, transfer function and YCbCr matrix, for
  /// `AVVideoColorPropertiesKey`: what `AVAssetExportSession` tags its SDR
  /// output with.
  ///
  /// Without the key the encoder still converts 8-bit RGB frames with the
  /// BT.709 matrix, but leaves the matrix unspecified (and every other tag
  /// too, for untagged frames), so FFmpeg-based players and transcoders decode
  /// the video as BT.601 and shift its colors.
  static let bt709: [String: Any] = [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
  ]
}
