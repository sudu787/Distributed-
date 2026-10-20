package dev.syncsphere.syncsphere_audio

import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.OpenableColumns
import java.io.File

/**
 * Music already on the phone (MediaStore) and audio shared to SyncSphere
 * from other apps ("Share → SyncSphere"). Files are copied into the app's
 * library on request; nothing is kept open or uploaded.
 */
object DeviceMedia {
    /** Songs longer than 30 s from the phone's music collection. */
    fun queryAudio(context: Context): List<Map<String, Any?>> {
        val collection = if (Build.VERSION.SDK_INT >= 29) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }
        val cols = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.DISPLAY_NAME,
        )
        val out = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(
            collection,
            cols,
            "${MediaStore.Audio.Media.IS_MUSIC} != 0 AND ${MediaStore.Audio.Media.DURATION} >= 30000",
            null,
            "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC",
        )?.use { c ->
            val id = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val title = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artist = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val album = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val albumId = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)
            val duration = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val size = c.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)
            val mime = c.getColumnIndexOrThrow(MediaStore.Audio.Media.MIME_TYPE)
            val name = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            while (c.moveToNext() && out.size < 20000) {
                out.add(
                    mapOf(
                        "uri" to ContentUris.withAppendedId(collection, c.getLong(id)).toString(),
                        "title" to cleanTag(c.getString(title)),
                        "artist" to cleanTag(c.getString(artist)),
                        "album" to cleanTag(c.getString(album)),
                        "albumId" to c.getLong(albumId),
                        "durationMs" to c.getLong(duration),
                        "size" to c.getLong(size),
                        "mime" to c.getString(mime),
                        "name" to c.getString(name),
                    ),
                )
            }
        }
        return out
    }

    /** MediaStore uses "<unknown>" for missing tags. */
    fun cleanTag(v: String?): String? = v?.trim()?.takeUnless { it.isEmpty() || it == "<unknown>" }

    /** Copies a content:// (or file://) URI to [out]; returns the byte count. */
    fun copyContent(context: Context, uri: String, out: File, maxBytes: Long = 512L * 1024 * 1024): Long {
        val part = File(out.path + ".part")
        out.parentFile?.mkdirs()
        var total = 0L
        try {
            context.contentResolver.openInputStream(Uri.parse(uri)).use { input ->
                requireNotNull(input) { "cannot open $uri" }
                part.outputStream().use { o ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        require(total <= maxBytes) { "file larger than 512 MB" }
                        o.write(buf, 0, n)
                    }
                }
            }
            require(total > 0) { "empty file" }
            if (!part.renameTo(out)) throw IllegalStateException("cannot move copied file")
            return total
        } finally {
            if (part.exists()) part.delete()
        }
    }

    /**
     * Audio URIs carried by a share intent (ACTION_SEND / ACTION_SEND_MULTIPLE
     * with an audio type or a generic type), as strings. Pure, so it can be
     * unit-tested without Android framework classes.
     */
    fun sharedUris(action: String?, type: String?, single: String?, multiple: List<String>?): List<String> {
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return emptyList()
        if (type != null && !(type.startsWith("audio/") || type == "*/*" || type == "application/octet-stream" ||
                type == "application/ogg")
        ) {
            return emptyList()
        }
        val raw = if (action == Intent.ACTION_SEND) listOfNotNull(single) else multiple.orEmpty()
        return raw.filter { it.startsWith("content://") || it.startsWith("file://") }.distinct().take(200)
    }

    @Suppress("DEPRECATION")
    fun sharedUris(intent: Intent?): List<String> {
        if (intent == null) return emptyList()
        val single = (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.toString()
        val multiple = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.map { it.toString() }
        return sharedUris(intent.action, intent.type, single, multiple)
    }

    /** Display name, size and type of a shared URI (best effort). */
    fun describe(context: Context, uri: String): Map<String, Any?> {
        val u = Uri.parse(uri)
        var name: String? = u.lastPathSegment
        var size: Long? = null
        try {
            context.contentResolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
                ?.use { c ->
                    if (c.moveToFirst()) {
                        c.getString(0)?.let { name = it }
                        if (!c.isNull(1)) size = c.getLong(1)
                    }
                }
        } catch (_: Exception) {
            // Not every provider answers OpenableColumns; the file is still readable.
        }
        return mapOf("uri" to uri, "name" to name, "size" to size, "mime" to context.contentResolver.getType(u))
    }
}
