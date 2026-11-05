package dev.syncsphere.syncsphere_audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Process

/**
 * Warm start: plays silence through an `AudioTrack` with the same
 * attributes as ExoPlayer's, so Android never puts the music output into
 * standby between songs. Waking a sleeping output costs tens to hundreds of
 * milliseconds and varies from start to start, which is what made phones
 * start apart ("echo at the start").
 */
class KeepAwake(private val sampleRate: Int) {
    @Volatile private var running = false
    private var thread: Thread? = null

    val isRunning: Boolean get() = running

    @Synchronized
    fun start(): String? {
        if (running) return null
        val track = try {
            build()
        } catch (e: Exception) {
            return "keep-awake output unavailable: ${e.message}"
        }
        running = true
        thread = Thread({ loop(track) }, "SyncSphereKeepAwake").apply { start() }
        return null
    }

    @Synchronized
    fun stop() {
        running = false
        thread?.join(500)
        thread = null
    }

    private fun build(): AudioTrack {
        val format = AudioFormat.Builder()
            .setSampleRate(sampleRate)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            .build()
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val minBuf = AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val track = AudioTrack.Builder()
            .setAudioAttributes(attrs)
            .setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(maxOf(minBuf, sampleRate / 10 * 4))
            .build()
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            throw IllegalStateException("AudioTrack not initialized")
        }
        return track
    }

    private fun loop(track: AudioTrack) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        val silence = ShortArray(sampleRate / 50 * 2) // 20 ms
        try {
            track.play()
            while (running) {
                if (track.write(silence, 0, silence.size) < 0) break
            }
        } catch (_: Exception) {
            // Output went away (e.g. audio server restart); warm start then
            // simply behaves like Classic.
        } finally {
            running = false
            try {
                track.stop()
            } catch (_: Exception) {
            }
            track.release()
        }
    }
}
