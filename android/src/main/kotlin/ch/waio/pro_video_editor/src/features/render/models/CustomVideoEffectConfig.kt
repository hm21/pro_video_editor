package ch.waio.pro_video_editor.src.features.render.models

/**
 * One custom video effect of a render: the id its implementation is registered
 * under, its settings, and its time range on the rendered video.
 *
 * Mirrors the Dart `CustomVideoEffect`.
 */
class CustomVideoEffectConfig(
    val id: String,
    val params: Map<String, Any?>,
    val startUs: Long?,
    val endUs: Long?,
) {
    /** Whether the effect draws the frame at [timeUs]. */
    fun isActiveAt(timeUs: Long): Boolean =
        (startUs == null || timeUs >= startUs) && (endUs == null || timeUs < endUs)

    /**
     * Whether the frame at [timeUs] has to be kept for an effect that looks
     * up to [maxOffsetUs] back: from that far ahead of the start, so the
     * effect starts with its full history, until the end.
     */
    fun keepsFrameAt(timeUs: Long, maxOffsetUs: Long): Boolean =
        (startUs == null || timeUs >= startUs - maxOffsetUs) && (endUs == null || timeUs < endUs)

    companion object {
        /** Parses one entry of the `customEffects` argument, or null without an id. */
        fun fromMap(map: Map<String, Any?>): CustomVideoEffectConfig? {
            val id = map["id"] as? String
            if (id.isNullOrEmpty()) return null
            val params = (map["params"] as? Map<*, *>)
                ?.entries
                ?.associate { (key, value) -> key.toString() to value }
                ?: emptyMap()
            return CustomVideoEffectConfig(
                id = id,
                params = params,
                startUs = (map["startUs"] as? Number)?.toLong(),
                endUs = (map["endUs"] as? Number)?.toLong(),
            )
        }
    }
}
