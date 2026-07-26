package ch.waio.pro_video_editor.src.features.render.models

/**
 * Thrown when the export could not acquire a video codec because the device's
 * codec resources were exhausted or the session was reclaimed by a
 * higher-priority client — not because anything is wrong with the video or the
 * requested configuration.
 *
 * Covers both ends of the pipeline: the *encoder* Media3 configures for the
 * output, and a *decoder* the export needs for its input. Both starve the same
 * way (a shared, finite MediaCodec pool) and both call for the same reaction, so
 * they share one type.
 *
 * The opposite case — an encoder that rejects the configuration itself — is
 * [VideoEncoderConfigurationException]: retrying that one is pointless, whereas
 * this failure is expected to succeed once codec sessions are released.
 *
 * The distinction is detected by
 * [ch.waio.pro_video_editor.src.features.render.helpers.EncoderFailureClassifier].
 */
class CodecResourceExhaustedException(
    message: String?,
    cause: Throwable? = null,
) : Exception(message, cause)
