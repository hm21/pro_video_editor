/// Exceptions thrown during render operations.
class RenderCanceledException implements Exception {
  /// Creates a [RenderCanceledException].
  const RenderCanceledException();

  @override
  String toString() => 'RenderCanceledException';
}

/// Thrown when the video could not be exported because no compatible encoder
/// configuration could be found for the device.
///
/// The native layer first retries through a fallback chain (capping the encoder
/// operating-rate, dropping it entirely, switching to a software encoder, then
/// downgrading the H.264 profile). This exception is only thrown once every
/// attempt has failed, so it signals a genuine device/format incompatibility
/// rather than a transient error — surface it to the user as an
/// "unsupported video/encoder" state rather than retrying.
class RenderEncoderException implements Exception {
  /// Creates a [RenderEncoderException] with an optional [message] describing
  /// the underlying encoder failure.
  const RenderEncoderException([this.message]);

  /// Human-readable details about the encoder failure, if available.
  final String? message;

  @override
  String toString() =>
      'RenderEncoderException${message != null ? ': $message' : ''}';
}
