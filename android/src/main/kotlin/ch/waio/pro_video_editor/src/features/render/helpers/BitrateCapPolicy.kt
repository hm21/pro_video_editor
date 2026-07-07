package ch.waio.pro_video_editor.src.features.render.helpers

/**
 * Decides whether a requested bitrate cap forces the video track through the
 * encoder instead of Media3's lossless transmux fast path.
 *
 * The requested bitrate is a guaranteed *maximum* for the rendered output.
 * Transmuxing copies the source samples verbatim, so it is only allowed when
 * every source video track already fits the cap (within [TOLERANCE], so
 * compliant sources keep the near-instant lossless path).
 *
 * Kept free of Android framework dependencies so it is unit-testable; the
 * actual source bitrates are probed by `MediaInfoExtractor.getVideoBitrate`.
 */
object BitrateCapPolicy {

    /**
     * Sources up to cap × tolerance keep the lossless fast path. The headroom
     * absorbs probe inaccuracy (the container-level fallback includes audio
     * and muxer overhead) and encoder rate-control drift around the target.
     */
    const val TOLERANCE = 1.2

    /**
     * Returns true when the video track must be re-encoded to honor the cap.
     *
     * @param requestedBitrate Requested maximum in bits per second, or null
     *  when no cap was requested (never forces encoding).
     * @param sourceBitrates Probed bitrate of each source video, in bits per
     *  second. A null entry means the bitrate could not be determined — the
     *  cap cannot be proven, so encoding is forced.
     * @param tolerance Multiplier on the cap below which a source counts as
     *  compliant.
     */
    fun shouldForceEncode(
        requestedBitrate: Int?,
        sourceBitrates: List<Long?>,
        tolerance: Double = TOLERANCE,
    ): Boolean {
        if (requestedBitrate == null) return false
        if (sourceBitrates.isEmpty()) return false
        val budget = requestedBitrate.toDouble() * tolerance
        return sourceBitrates.any { it == null || it.toDouble() > budget }
    }
}
