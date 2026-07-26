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
import androidx.media3.transformer.EncoderUtil
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
 *     software encoder (the slow last resort, see [VideoEncoderConfig]). The
 *     software attempt is skipped — with a log line saying so — when the device
 *     has no software encoder that accepts surface input for the target MIME
 *     type, because it would otherwise silently re-run the hardware encoder.
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
        // MIME Media3 will request the encoder for; used to decide whether the
        // software attempt can do anything at all. Resolved lazily so the happy
        // path (first attempt succeeds) never queries the codec list.
        val selectionMimeType = format.sampleMimeType ?: mimeType
        val softwareCandidates: List<MediaCodecInfo> by lazy(LazyThreadSafetyMode.NONE) {
            surfaceCapableSoftwareEncoders(selectionMimeType)
        }

        var lastError: ExportException? = null
        // First failure that was codec-resource pressure. Kept separately
        // because it must win over a later, permanent-looking error: once the
        // pool is starved the *software* attempt can fail with a plain
        // "format not supported" (Media3 finds no encoder matching the
        // resolution), which would otherwise mask the starvation and tell the
        // caller not to retry.
        var firstTransientError: ExportException? = null
        var failedAttempts = 0
        for (attempt in attempts) {
            if (attempt.useSoftwareEncoder && softwareCandidates.isEmpty()) {
                // Without this guard the selector would silently fall back to
                // the hardware candidates and the attempt would report a
                // `c2.qti.*` encoder under a "software" label — the exact log
                // that makes these failures unreadable.
                Log.w(
                    RENDER_TAG,
                    "Skipping encoder attempt '${attempt.label}': no " +
                            "surface-capable software encoder exists for " +
                            "$selectionMimeType, so a software fallback is a no-op " +
                            "(${describeSoftwareEncoderGap(selectionMimeType)})"
                )
                continue
            }
            try {
                val codec = buildFactoryForAttempt(attempt, sourceFrameRate)
                    .createForVideoEncoding(format, logSessionId)
                if (failedAttempts > 0) {
                    Log.w(
                        RENDER_TAG,
                        "Video encoder fallback succeeded using '${attempt.label}' " +
                                "after $failedAttempts failed attempt(s)"
                    )
                }
                return codec
            } catch (e: ExportException) {
                failedAttempts++
                val transient = EncoderFailureClassifier.isTransientResourceFailure(e)
                if (transient && firstTransientError == null) firstTransientError = e
                Log.w(
                    RENDER_TAG,
                    "Video encoder attempt '${attempt.label}' failed " +
                            "(${e.getErrorCodeName()}" +
                            (if (transient) ", transient codec-resource error" else "") +
                            "): ${e.message}"
                )
                lastError = e
            }
        }

        // Every attempt failed. A transient failure anywhere in the chain means
        // a retry can help, so it is surfaced in preference to the last error —
        // its message also names the real cause. Otherwise the last (typed,
        // descriptive) ExportException is re-thrown so it can be mapped to a
        // proper error state.
        throw firstTransientError ?: lastError ?: ExportException.createForUnexpected(
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
     * Restricts encoder selection to surface-capable software encoders.
     *
     * Deliberately *not* falling back to the hardware candidates: an empty list
     * makes Media3 fail this attempt, which is honest, whereas the fallback
     * would run the same hardware encoder that already failed and report it as
     * a "software" attempt. Callers guard the attempt with
     * [surfaceCapableSoftwareEncoders], which Media3 invokes with the same
     * `format.sampleMimeType` the guard reads, so in practice the empty case is
     * always skipped before it gets here — this is the honest fallback for a
     * Media3 version that queries the selector differently.
     */
    private fun softwareEncoderSelector(): EncoderSelector = EncoderSelector { mime ->
        ImmutableList.copyOf(surfaceCapableSoftwareEncoders(mime))
    }

    /**
     * Software encoders for [mime] that can be fed from an input `Surface`.
     *
     * Media3's video export always writes into the encoder's input surface, so
     * a software encoder that only accepts ByteBuffer/YUV input (common for
     * AVC) is unusable here even though it advertises the MIME type. Returns an
     * empty list when [mime] is null or nothing qualifies.
     */
    private fun surfaceCapableSoftwareEncoders(mime: String?): List<MediaCodecInfo> {
        if (mime == null) return emptyList()
        return EncoderSelector.DEFAULT.selectEncoderInfos(mime)
            .filter { isSoftwareEncoder(it) && supportsSurfaceInput(it, mime) }
    }

    /**
     * Human-readable reason why [surfaceCapableSoftwareEncoders] came up empty,
     * for the skip log: either the device ships no software encoder for the
     * MIME at all, or the ones it ships cannot take surface input.
     */
    private fun describeSoftwareEncoderGap(mime: String?): String {
        if (mime == null) return "no target MIME type"
        val software = EncoderSelector.DEFAULT.selectEncoderInfos(mime)
            .filter { isSoftwareEncoder(it) }
        return if (software.isEmpty()) {
            "device has no software encoder for this MIME"
        } else {
            "software encoder(s) ${software.joinToString { it.name }} reject " +
                    "surface input"
        }
    }

    /**
     * Whether [info] advertises `COLOR_FormatSurface` for [mime], i.e. whether
     * it can be driven by Media3's surface-based video pipeline.
     *
     * Fails *open*: an encoder that reports no color formats at all is treated
     * as unknown rather than unusable, so a device with an incomplete codec
     * description still gets its software attempt. A codec that genuinely
     * cannot take surface input then fails fast during init, which costs one
     * cheap attempt — far less than silently dropping a fallback that works.
     */
    private fun supportsSurfaceInput(info: MediaCodecInfo, mime: String): Boolean = try {
        val colorFormats = EncoderUtil.getSupportedColorFormats(info, mime)
        colorFormats.isEmpty() ||
                colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
    } catch (_: IllegalArgumentException) {
        // The encoder does not actually support this MIME type.
        false
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
