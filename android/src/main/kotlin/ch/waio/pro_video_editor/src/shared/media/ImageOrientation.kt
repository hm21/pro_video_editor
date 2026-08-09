package ch.waio.pro_video_editor.src.shared.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import java.io.File

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

    /** [probe] for an image whose bytes are already in memory. */
    fun probe(data: ByteArray): Probe? = probe(EncodedImage.OfBytes(data))

    /**
     * [probe] for stored dimensions that are already known, skipping the header
     * decode.
     */
    fun probeOf(storedWidth: Int, storedHeight: Int, image: EncodedImage): Probe {
        val orientation = read(image)
        val (width, height) = orientedSize(storedWidth, storedHeight, orientation)
        return Probe(width, height, orientation)
    }

    /** [probeOf] for an image whose bytes are already in memory. */
    fun probeOf(storedWidth: Int, storedHeight: Int, data: ByteArray): Probe =
        probeOf(storedWidth, storedHeight, EncodedImage.OfBytes(data))

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

    /** [read] for an image whose bytes are already in memory. */
    fun read(data: ByteArray): Int = read(EncodedImage.OfBytes(data))

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
     */
    fun decode(
        image: EncodedImage,
        reqWidth: Int = 0,
        reqHeight: Int = 0,
        config: Bitmap.Config? = null,
    ): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        decodeBitmap(image, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        // `inSampleSize` measures the stored pixels, so the request has to be
        // turned back into stored space first — the same swap, since exchanging
        // the two dimensions is its own inverse.
        val orientation = read(image)
        val (srcReqWidth, srcReqHeight) = orientedSize(reqWidth, reqHeight, orientation)

        val opts = BitmapFactory.Options().apply {
            inSampleSize =
                sampleSizeFor(bounds.outWidth, bounds.outHeight, srcReqWidth, srcReqHeight)
            if (config != null) inPreferredConfig = config
        }
        val raw = decodeBitmap(image, opts) ?: return null
        return orient(raw, orientation)
    }

    /** [decode] for an image whose bytes are already in memory. */
    fun decode(
        data: ByteArray,
        reqWidth: Int = 0,
        reqHeight: Int = 0,
        config: Bitmap.Config? = null,
    ): Bitmap? = decode(EncodedImage.OfBytes(data), reqWidth, reqHeight, config)

    /** Runs [BitmapFactory] over whichever source [image] holds. */
    private fun decodeBitmap(image: EncodedImage, opts: BitmapFactory.Options): Bitmap? =
        when (image) {
            is EncodedImage.OfBytes ->
                BitmapFactory.decodeByteArray(image.data, 0, image.data.size, opts)

            is EncodedImage.OfFile -> decodeFile(image.file, opts)
        }

    /**
     * `BitmapFactory.decodeFile` in stream form, so a file that cannot be opened
     * comes back as null instead of throwing.
     */
    private fun decodeFile(file: File, opts: BitmapFactory.Options): Bitmap? = try {
        file.inputStream().use { BitmapFactory.decodeStream(it, null, opts) }
    } catch (_: Exception) {
        null
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
