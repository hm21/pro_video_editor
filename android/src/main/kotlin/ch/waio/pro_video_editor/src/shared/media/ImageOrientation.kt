package ch.waio.pro_video_editor.src.shared.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface

/**
 * EXIF-aware decoding of caller-supplied encoded images.
 *
 * A photo straight from a phone's gallery stores a portrait shot as *landscape*
 * pixels plus an EXIF `Orientation` tag saying how to turn them. [BitmapFactory]
 * decodes the pixels and drops the tag, so the image renders sideways.
 *
 * Every path that takes an encoded image from the caller — the chroma-key
 * background, image layers, stop-motion frames — decodes through here, so they
 * agree with each other and with Darwin's `decodeOrientedImage`, which
 * normalizes the same way. The contract is: an encoded image renders the way
 * the user sees it in their photo library, whether it arrived as bytes or as a
 * file (see [EncodedImage]).
 */
internal object ImageOrientation {

    /** The eight orientations EXIF defines; anything else means "no transform". */
    private val DEFINED_ORIENTATIONS = intArrayOf(
        ExifInterface.ORIENTATION_NORMAL,
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL,
        ExifInterface.ORIENTATION_ROTATE_180,
        ExifInterface.ORIENTATION_FLIP_VERTICAL,
        ExifInterface.ORIENTATION_TRANSPOSE,
        ExifInterface.ORIENTATION_ROTATE_90,
        ExifInterface.ORIENTATION_TRANSVERSE,
        ExifInterface.ORIENTATION_ROTATE_270,
    )

    /** An encoded image's displayed size together with its EXIF orientation. */
    data class Probe(val width: Int, val height: Int, val orientation: Int)

    /**
     * Header-only probe: the **orientation-corrected** pixel size of [image]
     * plus the orientation itself, without holding a full-size bitmap.
     *
     * Returns null when the image does not decode.
     */
    fun probe(image: EncodedImage): Probe? {
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        decodeBitmap(image, opts)
        if (opts.outWidth <= 0 || opts.outHeight <= 0) return null
        return probeOf(opts.outWidth, opts.outHeight, image)
    }

    /**
     * [probe] for stored dimensions that are already known, skipping the header
     * decode.
     */
    fun probeOf(storedWidth: Int, storedHeight: Int, image: EncodedImage): Probe {
        val orientation = read(image)
        val (width, height) = orientedSize(storedWidth, storedHeight, orientation)
        return Probe(width, height, orientation)
    }

    /**
     * The EXIF orientation stored in [image], always one of the eight defined
     * values.
     *
     * An image with no tag reports `ORIENTATION_UNDEFINED`, and one that cannot
     * be read reports nothing at all; both come back as
     * [ExifInterface.ORIENTATION_NORMAL] so callers get a definite orientation
     * rather than a value they have to range-check themselves.
     */
    fun read(image: EncodedImage): Int {
        val orientation = try {
            image.openStream().use { stream ->
                ExifInterface(stream).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL
                )
            }
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        return if (orientation in DEFINED_ORIENTATIONS) {
            orientation
        } else {
            ExifInterface.ORIENTATION_NORMAL
        }
    }

    /** Whether [orientation] exchanges the image's width and height. */
    fun swapsDimensions(orientation: Int): Boolean = when (orientation) {
        ExifInterface.ORIENTATION_ROTATE_90,
        ExifInterface.ORIENTATION_ROTATE_270,
        ExifInterface.ORIENTATION_TRANSPOSE,
        ExifInterface.ORIENTATION_TRANSVERSE -> true

        else -> false
    }

    /** [width]×[height] as it is displayed once [orientation] has been applied. */
    fun orientedSize(width: Int, height: Int, orientation: Int): Pair<Int, Int> =
        if (swapsDimensions(orientation)) Pair(height, width) else Pair(width, height)

    /**
     * Decodes [image] and applies its EXIF orientation, so portrait photos are
     * not rendered sideways.
     *
     * When both [reqWidth] and [reqHeight] are positive the bitmap is decoded
     * downscaled toward that size instead of at full resolution — worth passing
     * whenever the caller is going to scale the result down anyway, since it
     * saves both the oversized decode and the oversized rotation copy. The
     * request is in *displayed* pixels, i.e. after the orientation. [config],
     * when given, is passed on as `inPreferredConfig`.
     *
     * A caller that has already probed the image passes the orientation it read
     * as [knownOrientation], so a file is not parsed for its EXIF twice.
     */
    fun decode(
        image: EncodedImage,
        reqWidth: Int = 0,
        reqHeight: Int = 0,
        config: Bitmap.Config? = null,
        knownOrientation: Int? = null,
    ): Bitmap? {
        val orientation = knownOrientation ?: read(image)

        // Reading the header is another open of the file, and it only earns
        // that when a downscale was actually asked for — without a target size
        // the sample size is 1 whatever the header turns out to say.
        val sampleSize = if (reqWidth > 0 && reqHeight > 0) {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            decodeBitmap(image, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

            // `inSampleSize` measures the stored pixels, so the request has to
            // be turned back into stored space first — the same swap, since
            // exchanging the two dimensions is its own inverse.
            val (srcReqWidth, srcReqHeight) = orientedSize(reqWidth, reqHeight, orientation)
            sampleSizeFor(bounds.outWidth, bounds.outHeight, srcReqWidth, srcReqHeight)
        } else {
            1
        }

        val opts = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            if (config != null) inPreferredConfig = config
        }
        val raw = decodeBitmap(image, opts) ?: return null
        return orient(raw, orientation)
    }

    /**
     * Decodes [image] oriented and no larger than [maxSize] in either
     * dimension.
     *
     * [decode] samples *toward* a requested size and may land a little above
     * it; this guarantees the ceiling, which is what a GL texture needs — one
     * pixel over the driver's `GL_MAX_TEXTURE_SIZE` and `createTexture` throws.
     * A caller that has already probed the image passes [knownProbe] so the
     * header is not read twice.
     */
    fun decodeWithin(
        image: EncodedImage,
        maxSize: Int,
        knownProbe: Probe? = null,
    ): Bitmap? {
        if (maxSize <= 0) return null
        val resolved = knownProbe ?: probe(image) ?: return null

        // Halve until both sides are inside the limit. `resolved` is oriented
        // and `inSampleSize` applies to the stored pixels, but an orientation
        // only ever exchanges the two dimensions, so the pair is over the limit
        // either way round.
        var sampleSize = 1
        while (resolved.width / sampleSize > maxSize ||
            resolved.height / sampleSize > maxSize
        ) {
            sampleSize *= 2
        }

        val opts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
        val raw = decodeBitmap(image, opts) ?: return null
        val decoded = orient(raw, resolved.orientation)

        // inSampleSize only halves, so one more exact pass may be needed.
        if (decoded.width <= maxSize && decoded.height <= maxSize) return decoded

        val scale = minOf(
            maxSize.toFloat() / decoded.width,
            maxSize.toFloat() / decoded.height,
        )
        val scaled = Bitmap.createScaledBitmap(
            decoded,
            (decoded.width * scale).toInt().coerceAtLeast(1),
            (decoded.height * scale).toInt().coerceAtLeast(1),
            /* filter= */ true
        )
        if (scaled !== decoded) decoded.recycle()
        return scaled
    }

    /** Runs [BitmapFactory] over whichever source [image] holds. */
    private fun decodeBitmap(image: EncodedImage, opts: BitmapFactory.Options): Bitmap? =
        when (image) {
            is EncodedImage.OfBytes ->
                BitmapFactory.decodeByteArray(image.data, 0, image.data.size, opts)

            // `decodeFile` already catches its own open failures and answers
            // null, so there is nothing to add around it here.
            is EncodedImage.OfFile ->
                BitmapFactory.decodeFile(image.file.absolutePath, opts)
        }

    /**
     * Turns [bitmap] the way [orientation] says it should be displayed.
     *
     * **Takes ownership of [bitmap].** Returns a new bitmap and recycles
     * [bitmap] when the orientation calls for a transform; returns [bitmap]
     * untouched otherwise (including for the "undefined" orientation a file
     * without the tag reports). Either way the caller must use the return value
     * and treat [bitmap] as gone.
     */
    fun orient(bitmap: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }

            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f)
                matrix.postScale(-1f, 1f)
            }

            else -> return bitmap
        }
        val transformed = Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true
        )
        if (transformed !== bitmap) bitmap.recycle()
        return transformed
    }

    /**
     * Largest power-of-two sample size that keeps the image ≥ the target size.
     *
     * A non-positive target means "no downscale", i.e. a sample size of 1.
     */
    fun sampleSizeFor(srcWidth: Int, srcHeight: Int, reqWidth: Int, reqHeight: Int): Int {
        if (reqWidth <= 0 || reqHeight <= 0) return 1
        var sample = 1
        var halfWidth = srcWidth / 2
        var halfHeight = srcHeight / 2
        while (halfWidth >= reqWidth && halfHeight >= reqHeight) {
            sample *= 2
            halfWidth /= 2
            halfHeight /= 2
        }
        return sample
    }
}
