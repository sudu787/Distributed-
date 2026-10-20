package dev.syncsphere.syncsphere_audio

import android.content.Intent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DeviceMediaTest {
    @Test
    fun singleAndMultipleAudioSharesAreAccepted() {
        assertEquals(
            listOf("content://media/external/audio/media/12"),
            DeviceMedia.sharedUris(Intent.ACTION_SEND, "audio/mpeg", "content://media/external/audio/media/12", null),
        )
        assertEquals(
            listOf("content://a/1", "file:///sdcard/b.flac"),
            DeviceMedia.sharedUris(
                Intent.ACTION_SEND_MULTIPLE,
                "audio/*",
                null,
                listOf("content://a/1", "file:///sdcard/b.flac", "content://a/1", "https://x.example/c.mp3"),
            ),
        )
    }

    @Test
    fun otherIntentsAndTypesAreIgnored() {
        assertTrue(DeviceMedia.sharedUris(Intent.ACTION_VIEW, "audio/mpeg", "content://a/1", null).isEmpty())
        assertTrue(DeviceMedia.sharedUris(Intent.ACTION_SEND, "image/png", "content://a/1", null).isEmpty())
        assertTrue(DeviceMedia.sharedUris(Intent.ACTION_SEND, "audio/mpeg", null, null).isEmpty())
        assertEquals(1, DeviceMedia.sharedUris(Intent.ACTION_SEND, null, "content://a/1", null).size)
    }

    @Test
    fun unknownTagsBecomeNull() {
        assertNull(DeviceMedia.cleanTag("<unknown>"))
        assertNull(DeviceMedia.cleanTag("  "))
        assertEquals("Nova", DeviceMedia.cleanTag(" Nova "))
    }
}
