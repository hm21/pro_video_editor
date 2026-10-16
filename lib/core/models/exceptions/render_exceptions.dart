import 'native_failure_details.dart';

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
  const RenderEncoderException([this.message, this.details])
    : isTransient = false;

  /// Creates a [RenderEncoderException] for a transient codec-resource failure
  /// with an optional [message], i.e. one that is worth retrying.
  const RenderEncoderException.transient([this.message, this.details])
    : isTransient = true;

  /// Human-readable details about the encoder failure, if available.
  final String? message;

  /// What the platform attached to the failure, or `null` when it attached
  /// nothing.
  ///
  /// On Android this names the Media3 error code behind the failure, which is
  /// where [codecKind] comes from.
  final NativeFailureDetails? details;

  /// Which codec could not be brought up, or `null` when the platform does not
  /// say.
  ///
  /// A transient failure covers a starved decoder as well as a starved encoder,
  /// and they call for different advice. A composition decodes all of its
  /// layers at once, one decoder each, and shares the device's decoders with
  /// everything else still holding one: preview players, a concurrent export,
  /// other apps. A [RenderCodecKind.decoder] shortage is therefore fixed by
  /// rendering fewer layers together or by releasing those players first; a
  /// shortage of the [RenderCodecKind.encoder] is fixed by neither. Read from
  /// the Media3 error code in [details], so only Android reports it.
  RenderCodecKind? get codecKind => switch (details?.codeName) {
    'ERROR_CODE_DECODER_INIT_FAILED' => RenderCodecKind.decoder,
    'ERROR_CODE_ENCODER_INIT_FAILED' ||
    'ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED' => RenderCodecKind.encoder,
    _ => null,
  };

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

/// The kind of codec a [RenderEncoderException] could not bring up.
enum RenderCodecKind {
  /// A decoder reading one of the render's inputs.
  decoder,

  /// The encoder writing the render's output.
  encoder,
}
