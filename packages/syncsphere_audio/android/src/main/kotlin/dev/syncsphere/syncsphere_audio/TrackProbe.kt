package dev.syncsphere.syncsphere_audio

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri

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
}
