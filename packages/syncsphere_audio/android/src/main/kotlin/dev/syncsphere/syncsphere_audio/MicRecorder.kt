package dev.syncsphere.syncsphere_audio

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.MediaRecorder
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min

/**
 * Records mono PCM for acoustic calibration and writes it as a WAV file.
 *
 * Uses the UNPROCESSED source when the device supports it (no AGC, noise
 * suppression or echo cancellation, which would distort click onsets),
 * otherwise VOICE_RECOGNITION (the least-processed common source).
 *
 * The first sample's capture time comes from `AudioRecord.getTimestamp`
 * (CLOCK_MONOTONIC) when available. Calibration only uses arrival
 * *differences*, so this timestamp merely locates the search windows.
 */
class MicRecorder(private val context: Context) {
    @SuppressLint("MissingPermission") // checked by the caller; SecurityException is reported
    fun record(startAtNanos: Long, durationMs: Long, sampleRate: Int, done: (Map<String, Any?>?, String?) -> Unit) {
        Thread {
            var rec: AudioRecord? = null
            try {
                val minBuf = AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                if (minBuf <= 0) throw IllegalStateException("unsupported recording format ($minBuf)")
                rec = AudioRecord(
                    source(),
                    sampleRate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    max(minBuf, sampleRate), // ≥ 0.5 s of buffer
                )
                if (rec.state != AudioRecord.STATE_INITIALIZED) throw IllegalStateException("microphone unavailable")
                val waitMs = (startAtNanos - System.nanoTime()) / 1_000_000
                if (waitMs > 0) Thread.sleep(waitMs)
                val startCall = System.nanoTime()
                rec.startRecording()
                val total = (sampleRate.toLong() * durationMs / 1000).toInt()
                val pcm = ShortArray(total)
                var read = 0
                var firstNanos: Long? = null
                val ts = AudioTimestamp()
                while (read < total) {
                    val n = rec.read(pcm, read, min(4096, total - read))
                    if (n < 0) throw IllegalStateException("AudioRecord.read failed ($n)")
                    read += n
                    if (firstNanos == null &&
                        rec.getTimestamp(ts, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS
                    ) {
                        firstNanos = ts.nanoTime - ts.framePosition * 1_000_000_000L / sampleRate
                    }
                }
                rec.stop()
                val file = File(context.cacheDir, "syncsphere-calibration-recording.wav")
                writeWav(file, pcm, sampleRate)
                done(
                    mapOf(
                        "path" to file.absolutePath,
                        "sampleRate" to sampleRate,
                        "firstSampleNanos" to (firstNanos ?: startCall),
                        "timestampSource" to if (firstNanos != null) "audioTimestamp" else "startCall",
                    ),
                    null,
                )
            } catch (e: SecurityException) {
                done(null, "microphone permission denied")
            } catch (e: Exception) {
                done(null, e.message ?: e.javaClass.simpleName)
            } finally {
                rec?.release()
            }
        }.apply { name = "SyncSphereMic" }.start()
    }

    private fun source(): Int {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val unprocessed = am.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"
        return if (unprocessed) MediaRecorder.AudioSource.UNPROCESSED else MediaRecorder.AudioSource.VOICE_RECOGNITION
    }

    private fun writeWav(file: File, pcm: ShortArray, rate: Int) {
        val data = pcm.size * 2
        val b = ByteBuffer.allocate(44 + data).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(36 + data).put("WAVE".toByteArray())
        b.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(rate).putInt(rate * 2)
            .putShort(2).putShort(16)
        b.put("data".toByteArray()).putInt(data)
        for (s in pcm) b.putShort(s)
        FileOutputStream(file).use { it.write(b.array()) }
    }
}
