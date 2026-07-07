package ch.waio.pro_video_editor.src.features.render.helpers

import BitrateChoice
import RENDER_TAG
import resolveBitrateSettings
import android.content.Context
import android.media.MediaCodecInfo
import android.media.metrics.LogSessionId
import android.os.Build
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Codec
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EncoderSelector
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.VideoEncoderSettings
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import com.google.common.collect.ImmutableList

/**
 * A [Codec.EncoderFactory] that hardens the video export against encoders which
 * reject an otherwise valid configuration.
 *
 * Media3's [DefaultEncoderFactory] picks a single encoder and fails the whole
 * export when its `configure()` / `start()` throws. On many Qualcomm
 * `c2.qti.*` encoders this happens because Media3 requests
 * `operating-rate = Integer.MAX_VALUE`. This factory:
 *
 *  1. Tries the fast configuration first (Media3's default
 *     `operating-rate = MAX`), so devices that work keep their original speed.
 *  2. Retries through a fallback chain when the encoder rejects it: capped
 *     operating-rate → operating-rate unset → Main profile → Baseline profile →
 *     software encoder (the slow last resort, see [VideoEncoderConfig]).
 *  3. Surfaces a descriptive [ExportException] (`ERROR_CODE_ENCODER_INIT_FAILED`)
 *     when every attempt fails, so the failure can be reported as a proper
 *     error state instead of a generic render failure.
 *
 * A failed attempt fails during codec init (before any frame is encoded) and
 * releases its codec, so the fallbacks are cheap.
 *
 * Audio encoding and the remux-vs-encode decision ([videoNeedsEncoding]) are
 * delegated to a plain [DefaultEncoderFactory] so behaviour for those is
 * unchanged.
 *
 * @param context Android context.
 * @param mimeType Target video MIME type (e.g. `video/avc`).
 * @param bitrate Requested bitrate in bits per second, or null for the encoder
 *  default.
 * @param forceVideoEncoding When true, [videoNeedsEncoding] reports that the
 *  video track must be encoded, disabling Media3's transmux fast path. Used to
 *  enforce the bitrate cap on sources whose bitrate exceeds it (see
 *  [BitrateCapPolicy]); a transmux would copy the source samples verbatim and
 *  ignore [bitrate] entirely.
 */
@UnstableApi
class ResilientVideoEncoderFactory(
    private val context: Context,
    private val mimeType: String?,
    bitrate: Int?,
    private val forceVideoEncoding: Boolean = false,
) : Codec.EncoderFactory {

    private val isAvc = mimeType == MimeTypes.VIDEO_H264

    /** Encoder-safe bitrate (clamped + mode), or null when none was requested. */
    private val bitrateChoice: BitrateChoice? = resolveBitrateSettings(mimeType, bitrate)

    /** Plain factory used for audio encoding. */
    private val baseFactory: DefaultEncoderFactory = DefaultEncoderFactory.Builder(context)
        .setEnableFallback(true)
        .build()

    override fun audioNeedsEncoding(): Boolean = baseFactory.audioNeedsEncoding()

    /**
     * Explicit remux-vs-encode decision. Media3 consults this in
     * `TransformerUtil.shouldTranscodeVideo`; everything else being equal
     * (single clip, no effects, matching MIME type), returning false keeps the
     * lossless transmux fast path and returning true forces the video track
     * through [createForVideoEncoding], where [bitrateChoice] is applied.
     */
    override fun videoNeedsEncoding(): Boolean = forceVideoEncoding

    override fun createForAudioEncoding(format: Format, logSessionId: LogSessionId?): Codec =
        baseFactory.createForAudioEncoding(format, logSessionId)

    override fun createForVideoEncoding(format: Format, logSessionId: LogSessionId?): Codec {
        val sourceFrameRate = format.frameRate.takeIf {
            it != Format.NO_VALUE.toFloat() && it > 0f
        }
        val attempts = VideoEncoderConfig.buildAttempts(
            sourceFrameRate = sourceFrameRate,
            includeProfileFallbacks = isAvc,
        )

        var lastError: ExportException? = null
        for ((index, attempt) in attempts.withIndex()) {
            try {
                val codec = buildFactoryForAttempt(attempt, sourceFrameRate)
                    .createForVideoEncoding(format, logSessionId)
                if (index > 0) {
                    Log.w(
                        RENDER_TAG,
                        "Video encoder fallback succeeded using '${attempt.label}' " +
                                "after $index failed attempt(s)"
                    )
                }
                return codec
            } catch (e: ExportException) {
                Log.w(
                    RENDER_TAG,
                    "Video encoder attempt '${attempt.label}' failed " +
                            "(${e.getErrorCodeName()}): ${e.message}"
                )
                lastError = e
            }
        }

        // Every attempt failed: re-throw the last (typed, descriptive)
        // ExportException so it can be mapped to a proper error state.
        throw lastError ?: ExportException.createForUnexpected(
            IllegalStateException("No video encoder attempts were available")
        )
    }

    /**
     * Builds a [DefaultEncoderFactory] for a single [EncoderAttempt], folding in
     * the resolved bitrate, the requested operating-rate/priority, an optional
     * forced profile/level, and an optional software-only encoder selector.
     */
    private fun buildFactoryForAttempt(
        attempt: EncoderAttempt,
        sourceFrameRate: Float?,
    ): DefaultEncoderFactory {
        val settings = VideoEncoderSettings.Builder().apply {
            bitrateChoice?.let {
                setBitrate(it.bitrate)
                setBitrateMode(it.bitrateMode)
            }
            // A null operatingRate leaves Media3's default performance settings
            // (operating-rate = MAX) for the fast first attempt. Otherwise we set
            // it explicitly: RATE_UNSET (-2) omits the key entirely, any other
            // value (e.g. a capped frame rate) is written verbatim.
            attempt.operatingRate?.let { rate ->
                setEncoderPerformanceParameters(rate, attempt.priority)
            }
            resolveProfileLevel(attempt.profile, sourceFrameRate)?.let { (profile, level) ->
                setEncodingProfileLevel(profile, level)
            }
        }.build()

        val builder = DefaultEncoderFactory.Builder(context)
            .setEnableFallback(true)
            .setRequestedVideoEncoderSettings(settings)

        if (attempt.useSoftwareEncoder) {
            builder.setVideoEncoderSelector(softwareEncoderSelector())
        }

        return builder.build()
    }

    /**
     * Maps an abstract [EncoderProfilePreference] to a concrete AVC
     * profile/level. Returns null for non-AVC output or
     * [EncoderProfilePreference.ENCODER_DEFAULT].
     */
    private fun resolveProfileLevel(
        profile: EncoderProfilePreference,
        sourceFrameRate: Float?,
    ): Pair<Int, Int>? {
        if (!isAvc) return null
        val avcProfile = when (profile) {
            EncoderProfilePreference.MAIN -> MediaCodecInfo.CodecProfileLevel.AVCProfileMain
            EncoderProfilePreference.BASELINE -> MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline
            EncoderProfilePreference.ENCODER_DEFAULT -> return null
        }
        return avcProfile to avcLevelForFrameRate(sourceFrameRate)
    }

    /** Picks an AVC level that covers 1080p at the given frame rate. */
    private fun avcLevelForFrameRate(sourceFrameRate: Float?): Int {
        val fps = sourceFrameRate ?: VideoEncoderConfig.DEFAULT_OPERATING_RATE.toFloat()
        return when {
            fps <= 30f -> MediaCodecInfo.CodecProfileLevel.AVCLevel4   // 1080p@30
            fps <= 60f -> MediaCodecInfo.CodecProfileLevel.AVCLevel42  // 1080p@60
            else -> MediaCodecInfo.CodecProfileLevel.AVCLevel5
        }
    }

    /**
     * Restricts encoder selection to software encoders, falling back to the
     * default candidate list when none are available.
     */
    private fun softwareEncoderSelector(): EncoderSelector = EncoderSelector { mime ->
        val all = EncoderSelector.DEFAULT.selectEncoderInfos(mime)
        val software = all.filter { isSoftwareEncoder(it) }
        ImmutableList.copyOf(if (software.isNotEmpty()) software else all)
    }

    private fun isSoftwareEncoder(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && info.isSoftwareOnly) {
            return true
        }
        val name = info.name.lowercase()
        return name.startsWith("c2.android.") ||
                name.startsWith("omx.google.") ||
                name.contains(".sw.") ||
                name.contains("software")
    }
}
