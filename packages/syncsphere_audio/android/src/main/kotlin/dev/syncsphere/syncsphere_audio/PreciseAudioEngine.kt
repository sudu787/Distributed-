package dev.syncsphere.syncsphere_audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import dev.syncsphere.syncsphere_audio.render.OutputClock
import dev.syncsphere.syncsphere_audio.render.RenderCore
import dev.syncsphere.syncsphere_audio.render.WavFileSource
import java.io.File
import java.util.concurrent.Executors

/**
 * The precise engine's Android half: one `AudioTrack` that runs for as long
 * as the engine is in use (so the output never sleeps), a writer thread at
 * `URGENT_AUDIO` priority that asks [RenderCore] what to write for every
 * output frame, and [OutputClock] fed from `AudioTrack.getTimestamp`, which
 * says when a written frame is actually heard.
 *
 * Times crossing the channel are `System.nanoTime()` values, like the
 * ExoPlayer engine; a start time here is the *audible* time of the first
 * frame. Every decision lives in the pure-Kotlin `render` package; this
 * class only moves bytes and timestamps.
 *
 * Failures (no output, write errors) are reported once as `engineFallback`
 * so the Dart side can switch the phone to Classic.
 */
class PreciseAudioEngine(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    companion object {
        private const val CHUNK_MS = 10
        private const val TIMESTAMP_POLL_NS = 20_000_000L
    }

    private val lock = Any()
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "SyncSpherePreciseIO") }

    val outRate: Int = (context.getSystemService(Context.AUDIO_SERVICE) as AudioManager)
        .getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull()?.takeIf { it in 8000..192000 } ?: 48000
    private val framesPerBuffer: Int = (context.getSystemService(Context.AUDIO_SERVICE) as AudioManager)
        .getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull() ?: 480

    // Guarded by [lock].
    private val pendingEvents = ArrayList<Map<String, Any?>>()
    private val core = RenderCore(outRate) { kind, segment, at, message ->
        pendingEvents.add(mapOf("kind" to kind, "segment" to segment, "atNanos" to at, "message" to message, "engine" to "precise"))
    }
    private val clock = OutputClock(outRate)

    @Volatile private var running = false
    private var track: AudioTrack? = null
    private var writer: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null

    /** Starts the output; returns an error message, or null when running. */
    @Synchronized
    fun start(): String? {
        if (running) return null
        val t = try {
            buildTrack()
        } catch (e: Exception) {
            return "no audio output for the precise engine: ${e.message ?: e.javaClass.simpleName}"
        }
        track = t
        running = true
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SyncSphere:precise").apply {
            setReferenceCounted(false)
            acquire()
        }
        writer = Thread({ writeLoop(t) }, "SyncSpherePrecise").apply { start() }
        return null
    }

    private fun buildTrack(): AudioTrack {
        val format = AudioFormat.Builder()
            .setSampleRate(outRate)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            .build()
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val minBuf = AudioTrack.getMinBufferSize(outRate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        // A few chunks of headroom against scheduling hiccups; scheduled
        // starts are placed by frame, so the buffer size does not affect timing.
        val bytes = maxOf(minBuf, outRate * CHUNK_MS / 1000 * 4 * 4)
        val t = AudioTrack.Builder()
            .setAudioAttributes(attrs)
            .setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(bytes)
            .build()
        if (t.state != AudioTrack.STATE_INITIALIZED) {
            t.release()
            throw IllegalStateException("AudioTrack not initialized")
        }
        return t
    }

    private fun writeLoop(t: AudioTrack) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val chunk = outRate * CHUNK_MS / 1000
        val buf = ShortArray(chunk * 2)
        val ts = AudioTimestamp()
        var written = 0L
        var lastPoll = 0L
        val fallbackLatencyNs = 2L * framesPerBuffer * 1_000_000_000L / outRate + 20_000_000L
        var failure: String? = null
        try {
            t.play()
            while (running) {
                val now = System.nanoTime()
                if (now - lastPoll >= TIMESTAMP_POLL_NS) {
                    lastPoll = now
                    val ok = t.getTimestamp(ts)
                    synchronized(lock) {
                        if (ok) clock.update(ts.framePosition, ts.nanoTime)
                        else clock.estimate(t.playbackHeadPosition.toLong() and 0xFFFFFFFFL, now, fallbackLatencyNs)
                    }
                }
                val events: List<Map<String, Any?>>
                synchronized(lock) {
                    core.render(buf, chunk, written, clock)
                    events = ArrayList(pendingEvents)
                    pendingEvents.clear()
                }
                for (e in events) main.post { emit(e) }
                var off = 0
                while (off < buf.size && running) {
                    val n = t.write(buf, off, buf.size - off)
                    if (n < 0) throw IllegalStateException("AudioTrack.write failed ($n)")
                    off += n
                }
                written += chunk
            }
        } catch (e: Exception) {
            failure = e.message ?: e.javaClass.simpleName
        } finally {
            try {
                t.stop()
            } catch (_: Exception) {
            }
            t.release()
        }
        if (failure != null && running) {
            running = false
            main.post {
                emit(mapOf("kind" to "engineFallback", "segment" to -1, "atNanos" to System.nanoTime(), "message" to failure, "engine" to "precise"))
            }
        }
    }

    // ----------------------------------------------------------- commands

    /** Opens the 16-bit PCM WAV at [uri] as standby segment [segmentId]. */
    fun prepare(segmentId: Int, uri: String, positionUs: Long, done: (String?) -> Unit) {
        io.execute {
            val err = try {
                val path = Uri.parse(uri).path ?: throw IllegalArgumentException("not a file uri: $uri")
                val src = WavFileSource.open(File(path))
                synchronized(lock) { core.prepare(segmentId, src, positionUs) }
                null
            } catch (e: Exception) {
                "decode_error: ${e.message ?: e.javaClass.simpleName}"
            }
            main.post { done(err) }
        }
    }

    fun startAt(segmentId: Int, atNanos: Long) = synchronized(lock) { core.startAt(segmentId, atNanos) }

    fun pauseAt(segmentId: Int, atNanos: Long, seekToUs: Long?) = synchronized(lock) { core.pauseAt(segmentId, atNanos, seekToUs) }

    fun setRate(rate: Double) = synchronized(lock) { core.rate = rate }

    fun setVolume(volume: Float) = synchronized(lock) { core.setVolume(volume) }

    fun setChannelRole(role: String) = synchronized(lock) { core.setRole(role) }

    fun stopPlayback() = synchronized(lock) { core.stop() }

    /** What is heard right now, in the same shape as the ExoPlayer engine's sample. */
    fun sample(): Map<String, Any?>? {
        val now = System.nanoTime()
        synchronized(lock) {
            val s = core.sample(now, clock) ?: return null
            return mapOf(
                "segment" to s.segment,
                "positionUs" to s.positionUs,
                "atNanos" to s.atNanos,
                "playing" to s.playing,
                "bufferedUs" to 5_000_000L,
                "rate" to core.rate,
                "state" to if (s.playing) "ready" else "paused",
                "fromTimestamp" to clock.fromTimestamp,
                "underruns" to (track?.underrunCount ?: 0),
            )
        }
    }

    /** Stops the output and releases everything. */
    @Synchronized
    fun release() {
        running = false
        writer?.join(500)
        writer = null
        track = null
        synchronized(lock) { core.stop() }
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    fun dispose() {
        release()
        io.shutdown()
    }
}
