package ch.waio.pro_video_editor.src.features.render.models

import kotlin.math.max

/**
 * A horizontal slice of the frame that is shifted sideways.
 *
 * Mirrors the Dart `VideoEffectBand`. [top] and [bottom] are fractions of the
 * frame height from the top edge, [shift] a fraction of its width; positive
 * moves the content right.
 */
data class VideoEffectBand(val top: Double, val bottom: Double, val shift: Double)

/**
 * The pixel operations of one frame of a video effect.
 *
 * Mirrors the Dart `VideoEffectFrame`, which defines what every field means.
 * Dart decides what an effect looks like at each point in time and sends the
 * result as a table of these; this side only applies them. The per-pixel
 * definition is [ch.waio.pro_video_editor.src.features.render.helpers.VideoEffectMath].
 */
data class VideoEffectFrame(
    val pixelSize: Double = 0.0,
    val rgbShift: Double = 0.0,
    val scanlines: Double = 0.0,
    val scanlinePeriod: Double = 0.0,
    val noise: Double = 0.0,
    val noiseCellSize: Double = 0.0,
    val noiseOffsetX: Int = 0,
    val noiseOffsetY: Int = 0,
    val bands: List<VideoEffectBand> = emptyList(),
    val sepia: Double = 0.0,
    val brightness: Double = 0.0,
    val invert: Double = 0.0,
    val flash: Double = 0.0,
    val vignette: Double = 0.0,
    val vignetteRadius: Double = 0.0,
) {
    /** Whether the frame leaves the picture unchanged. */
    val isIdentity: Boolean
        get() = pixelSize <= 0.0 && rgbShift == 0.0 && scanlines <= 0.0 &&
            noise <= 0.0 && bands.all { it.shift == 0.0 || it.bottom <= it.top } &&
            sepia <= 0.0 && brightness == 0.0 && invert <= 0.0 && flash <= 0.0 &&
            vignette <= 0.0

    /**
     * Combines two frames of overlapping effects, exactly as the Dart
     * `VideoEffectFrame.merge` does.
     */
    fun merge(other: VideoEffectFrame): VideoEffectFrame {
        if (other.isIdentity) return this
        if (isIdentity) return other
        val strongerScanlines = if (other.scanlines > scanlines) other else this
        val strongerNoise = if (other.noise > noise) other else this
        val strongerVignette = if (other.vignette > vignette) other else this
        return VideoEffectFrame(
            pixelSize = max(pixelSize, other.pixelSize),
            rgbShift = rgbShift + other.rgbShift,
            scanlines = strongerScanlines.scanlines,
            scanlinePeriod = strongerScanlines.scanlinePeriod,
            noise = strongerNoise.noise,
            noiseCellSize = strongerNoise.noiseCellSize,
            noiseOffsetX = strongerNoise.noiseOffsetX,
            noiseOffsetY = strongerNoise.noiseOffsetY,
            bands = (bands + other.bands).take(MAX_BANDS),
            sepia = max(sepia, other.sepia),
            brightness = brightness + other.brightness,
            invert = max(invert, other.invert),
            flash = max(flash, other.flash),
            vignette = strongerVignette.vignette,
            vignetteRadius = strongerVignette.vignetteRadius,
        )
    }

    companion object {
        /** The most bands a frame carries. */
        const val MAX_BANDS = 4

        /** Where the tone values start in a frame of the table, after the bands. */
        private const val TONE_OFFSET = 9 + MAX_BANDS * 3

        /** Values per frame in the table Dart sends. */
        const val STRIDE = TONE_OFFSET + 6

        /** A frame that leaves the picture unchanged. */
        val NONE = VideoEffectFrame()

        /** Reads the frame that starts at [offset] of a Dart-built table. */
        fun fromArray(values: DoubleArray, offset: Int): VideoEffectFrame {
            val bandCount = values[offset + 8].toInt().coerceIn(0, MAX_BANDS)
            return VideoEffectFrame(
                pixelSize = values[offset],
                rgbShift = values[offset + 1],
                scanlines = values[offset + 2],
                scanlinePeriod = values[offset + 3],
                noise = values[offset + 4],
                noiseCellSize = values[offset + 5],
                noiseOffsetX = values[offset + 6].toInt(),
                noiseOffsetY = values[offset + 7].toInt(),
                bands = List(bandCount) { i ->
                    VideoEffectBand(
                        top = values[offset + 9 + i * 3],
                        bottom = values[offset + 10 + i * 3],
                        shift = values[offset + 11 + i * 3],
                    )
                },
                sepia = values[offset + TONE_OFFSET],
                brightness = values[offset + TONE_OFFSET + 1],
                invert = values[offset + TONE_OFFSET + 2],
                flash = values[offset + TONE_OFFSET + 3],
                vignette = values[offset + TONE_OFFSET + 4],
                vignetteRadius = values[offset + TONE_OFFSET + 5],
            )
        }
    }
}

/**
 * One video effect: a looping table of [VideoEffectFrame]s, played back at
 * [frameRate] from [startUs] until [endUs] (exclusive).
 *
 * Mirrors the Dart `VideoEffect`, whose `frameAt` picks the same frame for the
 * same time, so a preview and this render agree.
 */
class VideoEffectConfig(
    val startUs: Long?,
    val endUs: Long?,
    val frameRate: Int,
    val frames: List<VideoEffectFrame>,
) {
    /** The frame at [timeUs] on the render timeline, or null when inactive. */
    fun frameAt(timeUs: Long): VideoEffectFrame? {
        if (frames.isEmpty()) return null
        if (startUs != null && timeUs < startUs) return null
        if (endUs != null && timeUs >= endUs) return null
        val localUs = max(0L, timeUs - (startUs ?: 0L))
        val bucket = localUs * frameRate / 1_000_000L
        return frames[(bucket % frames.size).toInt()]
    }

    companion object {
        /**
         * Where a frame at [timeUs] lands after a `SpeedChangeEffect` of [speed]
         * further down the chain, computed the way that effect computes it: from
         * the first frame of the stream, [streamStartUs], in float precision.
         */
        fun timeAfterSpeedChangeUs(timeUs: Long, streamStartUs: Long, speed: Float): Long {
            if (speed <= 0f || speed == 1f) return timeUs
            return (streamStartUs.toFloat() + (timeUs - streamStartUs).toFloat() / speed).toLong()
        }

        /** The combined frame of every effect active at [timeUs]. */
        fun resolve(effects: List<VideoEffectConfig>, timeUs: Long): VideoEffectFrame {
            var frame = VideoEffectFrame.NONE
            for (effect in effects) {
                val next = effect.frameAt(timeUs) ?: continue
                frame = frame.merge(next)
            }
            return frame
        }

        /**
         * Parses one entry of the `effects` argument, or null when it carries no
         * usable table.
         */
        fun fromMap(map: Map<String, Any?>): VideoEffectConfig? {
            val stride = (map["stride"] as? Number)?.toInt() ?: return null
            if (stride != VideoEffectFrame.STRIDE) return null
            val values: DoubleArray = when (val raw = map["frames"]) {
                is DoubleArray -> raw
                is List<*> -> raw.map { (it as Number).toDouble() }.toDoubleArray()
                else -> return null
            }
            val count = values.size / stride
            if (count == 0) return null
            return VideoEffectConfig(
                startUs = (map["startUs"] as? Number)?.toLong(),
                endUs = (map["endUs"] as? Number)?.toLong(),
                frameRate = max(1, (map["frameRate"] as? Number)?.toInt() ?: 24),
                frames = List(count) { VideoEffectFrame.fromArray(values, it * stride) },
            )
        }
    }
}
