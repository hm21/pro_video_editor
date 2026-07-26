/// Exceptions thrown during render operations.
class RenderCanceledException implements Exception {
  /// Creates a [RenderCanceledException].
  const RenderCanceledException();

  @override
  String toString() => 'RenderCanceledException';
}

/// Thrown when the video could not be exported because a video codec refused
/// the export.
///
/// Two very different failures share this type; [isTransient] tells them apart
/// and decides whether a retry makes sense:
///
/// * `isTransient == false` — a genuine device/format incompatibility. The
///   native layer already retried through its fallback chain (capping the
///   encoder operating-rate, dropping it entirely, downgrading the H.264
///   profile, switching to a software encoder) and every attempt was rejected.
///   Retrying the same export will fail the same way, so surface it to the user
///   as an "unsupported video/encoder" state.
/// * `isTransient == true` — a codec could not be acquired because the device's
///   codec resources were exhausted or the session was reclaimed by a
///   higher-priority client. This covers the encoder as well as a decoder the
///   export needed for its input. Nothing is wrong with the video or the
///   requested configuration: release other codec sessions (preview players,
///   decoders), wait briefly and retry.
class RenderEncoderException implements Exception {
  /// Creates a [RenderEncoderException] with an optional [message] describing
  /// the underlying encoder failure.
  ///
  /// Reports a permanent incompatibility; use
  /// [RenderEncoderException.transient] for a retryable codec-resource failure.
  const RenderEncoderException([this.message]) : isTransient = false;

  /// Creates a [RenderEncoderException] for a transient codec-resource failure
  /// with an optional [message], i.e. one that is worth retrying.
  const RenderEncoderException.transient([this.message]) : isTransient = true;

  /// Human-readable details about the encoder failure, if available.
  final String? message;

  /// Whether the failure was transient codec-resource pressure (retryable)
  /// rather than an incompatible encoder configuration.
  ///
  /// Only ever `true` on Android; other platforms always report `false`.
  final bool isTransient;

  @override
  String toString() =>
      'RenderEncoderException${isTransient ? '(transient)' : ''}'
      '${message != null ? ': $message' : ''}';
}
