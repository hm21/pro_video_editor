package ch.waio.pro_video_editor.src.features.render.helpers

import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.VideoEncoderSettings
import kotlin.math.roundToInt

/**
 * Profile preference for an encoder attempt.
 *
 * The concrete `MediaCodecInfo.CodecProfileLevel` value is resolved later by
 * [ResilientVideoEncoderFactory] so this (unit-testable) planner stays free of
 * Android framework dependencies.
 */
enum class EncoderProfilePreference {
    /** Let the encoder factory choose the profile (usually matches the source). */
    ENCODER_DEFAULT,

    /** Force H.264 Main profile. */
    MAIN,

    /** Force H.264 Baseline profile. */
    BASELINE,
}

/**
 * Describes a single encoder configuration attempt in the fallback chain.
 *
 * @property label Short identifier used in logs.
 * @property operatingRate `KEY_OPERATING_RATE` value to request via
 *  [VideoEncoderSettings]:
 *  - `null` leaves Media3's default performance settings untouched, i.e. the
 *    encoder runs at its fastest (`operating-rate = Integer.MAX_VALUE`). This is
 *    the original, fast behaviour.
 *  - [VideoEncoderSettings.RATE_UNSET] omits the key entirely.
 *  - any other value is written verbatim (e.g. a capped frame rate).
 * @property priority `KEY_PRIORITY` value. [VideoEncoderSettings.RATE_UNSET]
 *  means "leave it to the encoder". Ignored when [operatingRate] is `null`.
 * @property profile Profile to request (see [EncoderProfilePreference]).
 * @property useSoftwareEncoder When true, the factory should restrict the
 *  encoder selection to software encoders for this attempt.
 */
data class EncoderAttempt(
    val label: String,
    val operatingRate: Int?,
    val priority: Int,
    val profile: EncoderProfilePreference,
    val useSoftwareEncoder: Boolean,
)

/**
 * Builds safe video-encoder configurations for the render pipeline.
 *
 * Media3's `DefaultEncoderFactory` requests `KEY_OPERATING_RATE =
 * Integer.MAX_VALUE` for the fastest possible export. That is fine on most
 * devices, but a well known cause of `configure()` / `start()` failures on many
 * Qualcomm `c2.qti.*` encoders (the export aborts with a codec exception).
 *
 * Rather than slowing every device down, this helper keeps the fast setting as
 * the *first* attempt and only falls back to a capped (and progressively safer)
 * configuration when the encoder rejects it. Healthy devices therefore keep
 * their original speed, while fragile encoders still get a working export.
 *
 * The logic here is intentionally pure (no Android framework calls) so it can be
 * unit-tested.
 */
@UnstableApi
object VideoEncoderConfig {
    /** Operating-rate used when the source frame rate is unknown. */
    const val DEFAULT_OPERATING_RATE = 30

    /**
     * Upper bound for the capped operating-rate. Guards against absurd source
     * frame rates while still allowing common 30/60 fps content through
     * unchanged.
     */
    const val MAX_OPERATING_RATE = 240

    /**
     * Resolves the capped `KEY_OPERATING_RATE` used by the fallback attempts.
     *
     * @param sourceFrameRate Source video frame rate, or null when unknown.
     * @return The rounded source frame rate (clamped to a sane range), or
     *  [DEFAULT_OPERATING_RATE] when it is unknown/invalid.
     */
    fun resolveOperatingRate(sourceFrameRate: Float?): Int {
        val fps = sourceFrameRate
        if (fps == null || !fps.isFinite() || fps <= 0f) return DEFAULT_OPERATING_RATE
        return fps.roundToInt().coerceIn(1, MAX_OPERATING_RATE)
    }

    /**
     * Builds the ordered list of encoder attempts to try.
     *
     * The chain is, in order:
     *  1. Hardware encoder at full speed (`operating-rate = MAX`, Media3's
     *     default) — keeps the original performance on devices that work.
     *  2. Hardware encoder with the operating-rate capped to the source frame
     *     rate (the primary fix for encoders that reject MAX).
     *  3. Hardware encoder with the operating-rate key omitted entirely.
     *  4. Hardware encoder forced to H.264 Main profile (only for AVC).
     *  5. Hardware encoder forced to H.264 Baseline profile (only for AVC).
     *  6. A software encoder.
     *
     * All hardware attempts are tried first because a rejected attempt fails
     * fast (during codec init, before any frame is encoded). The software
     * encoder is genuinely slower at 1080p, so it is deliberately the very last
     * resort — only reached when every fast hardware option has failed.
     *
     * @param sourceFrameRate Source frame rate used to cap the operating-rate.
     * @param includeProfileFallbacks Whether to include the Main/Baseline
     *  profile attempts (H.264 only).
     */
    fun buildAttempts(
        sourceFrameRate: Float?,
        includeProfileFallbacks: Boolean = true,
    ): List<EncoderAttempt> {
        val cappedRate = resolveOperatingRate(sourceFrameRate)
        val unset = VideoEncoderSettings.RATE_UNSET

        val attempts = mutableListOf(
            EncoderAttempt(
                label = "hw-fast-operating-rate",
                // null → keep Media3's default (operating-rate = MAX), i.e. the
                // original, fastest behaviour. Healthy devices succeed here.
                operatingRate = null,
                priority = unset,
                profile = EncoderProfilePreference.ENCODER_DEFAULT,
                useSoftwareEncoder = false,
            ),
            EncoderAttempt(
                label = "hw-capped-operating-rate",
                operatingRate = cappedRate,
                priority = unset,
                profile = EncoderProfilePreference.ENCODER_DEFAULT,
                useSoftwareEncoder = false,
            ),
            EncoderAttempt(
                label = "hw-operating-rate-unset",
                operatingRate = unset,
                priority = unset,
                profile = EncoderProfilePreference.ENCODER_DEFAULT,
                useSoftwareEncoder = false,
            ),
        )

        if (includeProfileFallbacks) {
            attempts += EncoderAttempt(
                label = "hw-main-profile",
                operatingRate = cappedRate,
                priority = unset,
                profile = EncoderProfilePreference.MAIN,
                useSoftwareEncoder = false,
            )
            attempts += EncoderAttempt(
                label = "hw-baseline-profile",
                operatingRate = cappedRate,
                priority = unset,
                profile = EncoderProfilePreference.BASELINE,
                useSoftwareEncoder = false,
            )
        }

        // Software encoder is the slow last resort, reached only when every
        // hardware attempt above has failed.
        attempts += EncoderAttempt(
            label = "software-encoder",
            operatingRate = cappedRate,
            priority = unset,
            profile = EncoderProfilePreference.ENCODER_DEFAULT,
            useSoftwareEncoder = true,
        )

        return attempts
    }
}
