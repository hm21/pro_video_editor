import android.media.MediaCodecInfo
import android.media.MediaCodecList
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.VideoEncoderSettings
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log

/**
 * An encoder-safe bitrate configuration: a bitrate clamped to the codec's
 * supported range plus a bitrate mode the codec actually accepts.
 *
 * @property bitrate Bitrate in bits per second.
 * @property bitrateMode One of [MediaCodecInfo.EncoderCapabilities] BITRATE_MODE_*.
 */
data class BitrateChoice(val bitrate: Int, val bitrateMode: Int)

/**
 * Resolves an encoder-safe bitrate configuration for the given MIME type.
 *
 * - Clamps the requested bitrate into the codec's supported range
 * - Uses CBR (Constant Bitrate) for predictable file size when supported and
 *   the bitrate is not in the upper portion of the range
 * - Falls back to VBR (Variable Bitrate) when CBR is unsupported or the
 *   bitrate is high, since high-bitrate CBR is frequently rejected by
 *   hardware encoders
 *
 * @param mimeType Video MIME type (e.g., "video/avc" for H.264)
 * @param bitrate Target bitrate in bits per second, or null to leave the
 *  encoder on its default bitrate.
 * @return The resolved [BitrateChoice], or null when no bitrate was requested or
 *  no encoder could be found for [mimeType].
 */
@UnstableApi
fun resolveBitrateSettings(mimeType: String?, bitrate: Int?): BitrateChoice? {
    if (bitrate == null) return null
    Log.d(RENDER_TAG, "Configuring bitrate: ${bitrate / 1000} kbps")

    val codecInfo = MediaCodecList(MediaCodecList.ALL_CODECS)
        .codecInfos
        .firstOrNull { it.isEncoder && it.supportedTypes.contains(mimeType) }

    if (codecInfo == null) {
        Log.e(RENDER_TAG, "No encoder found for $mimeType")
        return null
    }

    val capabilities = codecInfo.getCapabilitiesForType(mimeType)
    val bitrateRange = capabilities.videoCapabilities.bitrateRange
    val supportsCBR = capabilities.encoderCapabilities
        .isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)

    // Clamp the requested bitrate into the supported range instead of bailing
    // out. Bailing left the encoder on its (often very high) default bitrate,
    // which is one of the configurations Qualcomm encoders reject outright.
    val safeBitrate = bitrate.coerceIn(bitrateRange.lower, bitrateRange.upper)
    if (safeBitrate != bitrate) {
        Log.w(
            RENDER_TAG,
            "Bitrate ${bitrate / 1000} kbps outside supported range " +
                    "${bitrateRange.lower / 1000}-${bitrateRange.upper / 1000} kbps, " +
                    "clamping to ${safeBitrate / 1000} kbps"
        )
    }

    // CBR at a high bitrate (relative to the codec's max) is the combination
    // most likely to be rejected by hardware encoders (e.g. Qualcomm AVC at
    // 1080p with High profile). When the requested bitrate sits in the upper
    // portion of the supported range, prefer VBR which is far more forgiving.
    val highBitrateThreshold = (bitrateRange.upper * 0.8).toInt()
    val useCBR = supportsCBR && safeBitrate <= highBitrateThreshold

    val bitrateMode = if (useCBR) {
        Log.d(RENDER_TAG, "Using CBR (Constant Bitrate) mode")
        MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
    } else {
        val reason = if (!supportsCBR) "CBR not supported" else "high bitrate, avoiding CBR"
        Log.d(RENDER_TAG, "Using VBR (Variable Bitrate) mode ($reason)")
        MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
    }

    return BitrateChoice(safeBitrate, bitrateMode)
}

/**
 * Configures video encoder bitrate settings on [encoderFactoryBuilder].
 *
 * Thin wrapper around [resolveBitrateSettings] kept for callers (e.g.
 * stop-motion rendering) that configure a [DefaultEncoderFactory.Builder]
 * directly.
 *
 * @param encoderFactoryBuilder Encoder factory to configure
 * @param mimeType Video MIME type (e.g., "video/avc" for H.264)
 * @param bitrate Target bitrate in bits per second
 */
@UnstableApi
fun applyBitrate(
    encoderFactoryBuilder: DefaultEncoderFactory.Builder,
    mimeType: String?,
    bitrate: Int?
) {
    val choice = resolveBitrateSettings(mimeType, bitrate) ?: return
    encoderFactoryBuilder.setRequestedVideoEncoderSettings(
        VideoEncoderSettings.Builder()
            .setBitrateMode(choice.bitrateMode)
            .setBitrate(choice.bitrate)
            .build()
    )
}
