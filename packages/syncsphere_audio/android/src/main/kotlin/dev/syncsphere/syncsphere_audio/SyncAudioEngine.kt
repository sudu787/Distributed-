package dev.syncsphere.syncsphere_audio

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.mp3.Mp3Extractor
import kotlin.math.abs

/**
 * Native half of the SyncSphere audio backend.
 *
 * All ExoPlayer instances live on one dedicated [HandlerThread] running at
 * `THREAD_PRIORITY_URGENT_AUDIO`, which is also their application looper, so
 * scheduled play calls are not queued behind Flutter UI work on the main
 * thread.
 *
 * Segments: at most one *active* player (playing or paused) and one
 * *standby* player (prepared, buffered, paused at its start position).
 * Starting the standby pauses and releases the old active player and starts
 * the new one at the scheduled instant, so a scheduled seek or track change
 * does not have to wait for re-buffering.
 *
 * Timing: all times crossing the channel are `System.nanoTime()` values
 * (CLOCK_MONOTONIC). The Dart side bridges its own monotonic clock to this
 * domain. A play call is posted with `Handler.postAtTime` (millisecond
 * resolution, a few ms of jitter) a little early and then busy-waits on
 * `System.nanoTime()` for the final [SPIN_MS] milliseconds.
 *
 * What this does *not* control: the delay between `ExoPlayer.play()` and
 * sound leaving the DAC (message passing to ExoPlayer's playback thread,
 * `AudioTrack.play()`, mixer and HAL buffers). The Dart engine measures and
 * learns that delay from position reports.
 */
class SyncAudioEngine(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    companion object {
        private const val SPIN_MS = 3L
        private const val SAMPLE_COUNT = 7
        private const val SAMPLE_SPACING_MS = 2L
        private const val RELEASE_DELAY_MS = 400L
    }

    private class Segment(val id: Int, val uri: String, val player: ExoPlayer, val role: String) {
        @Volatile var ready = false
    }

    private val thread = HandlerThread("SyncSphereAudio", Process.THREAD_PRIORITY_URGENT_AUDIO).apply { start() }
    private val handler = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())

    // Only touched on [thread].
    private var active: Segment? = null
    private var standby: Segment? = null
    private var rate = 1f
    private var volume = 1f
    private var channelRole = "stereo"

    // ------------------------------------------------------------ prepare

    fun prepare(segmentId: Int, uri: String, positionUs: Long, done: (String?) -> Unit) {
        handler.post {
            try {
                prepareOnThread(segmentId, uri, positionUs, done)
            } catch (e: Exception) {
                main.post { done("prepare_error: ${e.message}") }
            }
        }
    }

    private fun prepareOnThread(segmentId: Int, uri: String, positionUs: Long, done: (String?) -> Unit) {
        val old = standby
        if (old != null && old.player !== active?.player) releaseLater(old.player)
        standby = null

        // Resume optimisation: the paused active player is already buffered at
        // the requested position, so reuse it instead of creating a new one.
        val a = active
        if (a != null && a.uri == uri && a.role == channelRole && !a.player.isPlaying &&
            a.player.playbackState == Player.STATE_READY &&
            abs(a.player.currentPosition * 1000 - positionUs) <= 2000
        ) {
            standby = Segment(segmentId, uri, a.player, a.role).also { it.ready = true }
            main.post { done(null) }
            return
        }

        val player = buildPlayer()
        val seg = Segment(segmentId, uri, player, channelRole)
        standby = seg
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_READY && !seg.ready) {
                    seg.ready = true
                    main.post { done(null) }
                }
                onStateForEvents(seg, playbackState)
            }

            override fun onPlayerError(error: PlaybackException) {
                if (!seg.ready) {
                    if (standby === seg) standby = null
                    releaseLater(player)
                    main.post { done("decode_error: ${error.errorCodeName}: ${error.message}") }
                } else {
                    emitEvent("error", seg.id, "${error.errorCodeName}: ${error.message}")
                }
            }
        })
        player.setMediaItem(MediaItem.fromUri(Uri.parse(uri)), positionUs / 1000)
        player.prepare()
    }

    private fun buildPlayer(): ExoPlayer {
        // Index seeking only helps VBR MP3 *without* a seek table; files with
        // a Xing table of contents still seek approximately. The Dart side
        // therefore plays exact PCM copies of MP3/ADTS files
        // (TrackTranscoder / ConvertingTrackResolver).
        val extractors = DefaultExtractorsFactory()
            .setConstantBitrateSeekingEnabled(true)
            .setMp3ExtractorFlags(Mp3Extractor.FLAG_ENABLE_INDEX_SEEKING)
        val attrs = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()
        // The channel role is baked into the audio sink, so a role change
        // takes effect with the next prepared segment.
        val player = ExoPlayer.Builder(context, RoleRenderersFactory(context, channelRole))
            .setLooper(thread.looper)
            .setMediaSourceFactory(DefaultMediaSourceFactory(context, extractors))
            // Audio focus handling would pause this device on its own and
            // silently desynchronise it; the room decides when to pause.
            .setAudioAttributes(attrs, false)
            .setHandleAudioBecomingNoisy(false)
            .setWakeMode(C.WAKE_MODE_LOCAL)
            .build()
        player.playWhenReady = false
        player.volume = volume
        player.playbackParameters = PlaybackParameters(1f)
        player.setSeekParameters(SeekParameters.EXACT)
        return player
    }

    // -------------------------------------------------------- scheduling

    /** Schedules the play call of [segmentId] at `System.nanoTime() == atNanos`. */
    fun startAt(segmentId: Int, atNanos: Long) = scheduleAt(atNanos) { startNow(segmentId) }

    fun pauseAt(segmentId: Int, atNanos: Long, seekToUs: Long?) = scheduleAt(atNanos) {
        val a = active
        if (a != null && a.id == segmentId) {
            a.player.pause()
            if (seekToUs != null) a.player.seekTo(seekToUs / 1000)
            emitEvent("paused", segmentId, null)
        }
    }

    private fun scheduleAt(atNanos: Long, action: () -> Unit) {
        val leadMs = (atNanos - System.nanoTime()) / 1_000_000 - SPIN_MS
        val runnable = Runnable { spinUntil(atNanos); action() }
        if (leadMs <= 0) handler.post(runnable) else handler.postAtTime(runnable, SystemClock.uptimeMillis() + leadMs)
    }

    private fun spinUntil(atNanos: Long) {
        // Bounded busy-wait for sub-millisecond release of the play call.
        val limit = System.nanoTime() + (SPIN_MS + 2) * 1_000_000
        while (true) {
            val now = System.nanoTime()
            if (now >= atNanos || now >= limit) return
        }
    }

    private fun startNow(segmentId: Int) {
        val sb = standby
        val a = active
        val target = when {
            sb != null && sb.id == segmentId -> sb
            a != null && a.id == segmentId -> a
            else -> null
        }
        if (target == null) {
            emitEvent("error", segmentId, "segment $segmentId is not prepared")
            return
        }
        if (target === sb) {
            if (a != null && a.player !== sb.player) {
                a.player.pause()
                releaseLater(a.player)
            }
            active = sb
            standby = null
        }
        // A new segment always starts at nominal rate; drift control
        // re-applies corrections afterwards.
        rate = 1f
        target.player.playbackParameters = PlaybackParameters(1f)
        val calledAt = System.nanoTime()
        target.player.play()
        emitEvent("playCalled", segmentId, null, calledAt)
    }

    // --------------------------------------------------------- controls

    fun setRate(r: Float) = handler.post {
        rate = r
        active?.player?.playbackParameters = PlaybackParameters(r)
    }

    fun setVolume(v: Float) = handler.post {
        volume = v
        active?.player?.volume = v
        standby?.player?.volume = v
    }

    /** "stereo", "left", "right" or "mono"; applies from the next segment. */
    fun setChannelRole(role: String) = handler.post { channelRole = role }

    fun stop() = handler.post {
        standby?.let { if (it.player !== active?.player) it.player.release() }
        active?.player?.release()
        active = null
        standby = null
    }

    /** Samples the active segment's rendered position (see [PositionEstimator]). */
    fun sample(done: (Map<String, Any?>?) -> Unit) {
        handler.post {
            val a = active
            if (a == null) {
                main.post { done(null) }
                return@post
            }
            val readings = ArrayList<PositionEstimator.Reading>(SAMPLE_COUNT)
            readings.add(PositionEstimator.Reading(a.player.currentPosition, System.nanoTime()))
            val step = object : Runnable {
                override fun run() {
                    if (active !== a) {
                        main.post { done(null) }
                        return
                    }
                    readings.add(PositionEstimator.Reading(a.player.currentPosition, System.nanoTime()))
                    if (readings.size < SAMPLE_COUNT && a.player.isPlaying) {
                        handler.postDelayed(this, SAMPLE_SPACING_MS)
                        return
                    }
                    val p = a.player
                    val speed = p.playbackParameters.speed
                    val est = PositionEstimator.estimate(readings, speed, p.isPlaying)!!
                    val state = when (p.playbackState) {
                        Player.STATE_BUFFERING -> "buffering"
                        Player.STATE_ENDED -> "ended"
                        Player.STATE_IDLE -> "idle"
                        else -> if (p.isPlaying) "ready" else "paused"
                    }
                    val result = mapOf<String, Any?>(
                        "segment" to a.id,
                        "positionUs" to est.positionUs,
                        "atNanos" to est.atNanos,
                        "playing" to p.isPlaying,
                        "bufferedUs" to (p.bufferedPosition - p.currentPosition).coerceAtLeast(0) * 1000,
                        "rate" to speed.toDouble(),
                        "state" to state,
                    )
                    main.post { done(result) }
                }
            }
            handler.postDelayed(step, SAMPLE_SPACING_MS)
        }
    }

    fun dispose() {
        stop()
        handler.post { thread.quitSafely() }
    }

    // ----------------------------------------------------------- events

    private fun onStateForEvents(seg: Segment, state: Int) {
        if (active !== seg && active?.player !== seg.player) return
        when (state) {
            Player.STATE_BUFFERING -> if (seg.player.playWhenReady) emitEvent("stalled", seg.id, null)
            Player.STATE_READY -> if (seg.player.playWhenReady) emitEvent("resumedAfterStall", seg.id, null)
            Player.STATE_ENDED -> emitEvent("ended", seg.id, null)
            else -> {}
        }
    }

    private fun emitEvent(kind: String, segment: Int, message: String?, atNanos: Long = System.nanoTime()) {
        emit(mapOf("kind" to kind, "segment" to segment, "atNanos" to atNanos, "message" to message))
    }

    private fun releaseLater(player: ExoPlayer) {
        handler.postDelayed({ player.release() }, RELEASE_DELAY_MS)
    }
}
