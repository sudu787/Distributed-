package dev.syncsphere.syncsphere_audio

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import java.io.File
import java.io.FileOutputStream

/** Reads duration and tags of a local audio file (no decoding). */
object TrackProbe {
    fun probe(context: Context, uri: String): Map<String, Any?> {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(context, Uri.parse(uri))
            return mapOf(
                "durationMs" to r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull(),
                "title" to r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE),
                "artist" to r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST),
                "album" to r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM),
                "mimeType" to r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE),
            )
        } finally {
            r.release()
        }
    }

    /**
     * Writes the embedded cover picture as a JPEG no larger than [maxPx] on
     * its longest side. Returns false when the file has no picture.
     */
    fun artwork(context: Context, uri: String, out: File, maxPx: Int = 512): Boolean {
        val r = MediaMetadataRetriever()
        val bytes: ByteArray?
        try {
            r.setDataSource(context, Uri.parse(uri))
            bytes = r.embeddedPicture
        } finally {
            r.release()
        }
        if (bytes == null) return false
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return false
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxPx) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return false
        val scale = maxPx.toFloat() / maxOf(decoded.width, decoded.height)
        val bmp = if (scale < 1f) {
            Bitmap.createScaledBitmap(decoded, (decoded.width * scale).toInt().coerceAtLeast(1), (decoded.height * scale).toInt().coerceAtLeast(1), true)
        } else {
            decoded
        }
        out.parentFile?.mkdirs()
        val tmp = File(out.parentFile, out.name + ".part")
        FileOutputStream(tmp).use { bmp.compress(Bitmap.CompressFormat.JPEG, 85, it) }
        if (bmp !== decoded) bmp.recycle()
        decoded.recycle()
        return tmp.renameTo(out)
    }
}
