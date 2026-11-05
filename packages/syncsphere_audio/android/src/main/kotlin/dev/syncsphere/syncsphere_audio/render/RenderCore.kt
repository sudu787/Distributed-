package dev.syncsphere.syncsphere_audio.render

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * Everything the precise renderer decides, without Android: what to write
 * at each output frame. The Android glue ([dev.syncsphere.syncsphere_audio
 * .PreciseAudioEngine]) only moves the result to an `AudioTrack` and feeds
 * [OutputClock] with hardware timestamps.
 *
 * ## Timing
 * A start "at T" means: the segment's first frame is *heard* at
 * `System.nanoTime() == T`. Through the clock, T becomes an output frame,
 * and the switch from silence to content happens on exactly that frame. A
 * start that is already due when it is processed begins at once, skipping
 * the content that should have played meanwhile, so it is still aligned.
 * Pauses work the same way.
 *
 * ## Segments
 * Like the ExoPlayer engine: at most one *active* segment (playing or
 * paused) and prepared *standby* segments waiting for their start.
 *
 * Not thread-safe; the caller serializes access.
 */
class RenderCore(
    val outRate: Int,
    private val emit: (kind: String, segment: Int, atNanos: Long, message: String?) -> Unit,
) {
    companion object {
        /** Fade length (frames at 48 kHz ≈ 3 ms) around starts, pauses and switches. */
        const val FADE_MS = 3

        /** At most this many prepared segments are kept. */
        const val MAX_STANDBY = 2
    }

    private class Segment(val id: Int, val src: PcmSource, var pos: Double) {
        var playing = false
        var ended = false

        /** Output frame where content started (for the fade-in). */
        var startedAt = Long.MIN_VALUE
    }

    private sealed class Command(val segment: Int, val atNanos: Long) {
        class Start(segment: Int, atNanos: Long) : Command(segment, atNanos)
        class Pause(segment: Int, atNanos: Long, val seekToUs: Long?) : Command(segment, atNanos)
    }

    private val fade = max(1, outRate * FADE_MS / 1000)
    private val standby = LinkedHashMap<Int, Segment>()
    private var active: Segment? = null
    private val commands = ArrayList<Command>()
    private val resampler = Resampler()
    private var mixBuf = FloatArray(0)

    val content = ContentMap()

    var rate = 1.0
        set(v) {
            field = v.coerceIn(0.5, 2.0)
        }
    private var volumeTarget = 1f
    private var volume = 1f
    private var mix = ChannelRoles.matrix("stereo")

    val activeSegment: Int? get() = active?.id
    val isPlaying: Boolean get() = active?.playing == true
    val hasWork: Boolean get() = active != null || standby.isNotEmpty() || commands.isNotEmpty()

    // ------------------------------------------------------------ inputs

    /** Prepares [src] as standby segment [id], positioned at [positionUs]. */
    fun prepare(id: Int, src: PcmSource, positionUs: Long) {
        standby.remove(id)?.src?.close()
        while (standby.size >= MAX_STANDBY) {
            val oldest = standby.keys.first()
            standby.remove(oldest)?.src?.close()
        }
        standby[id] = Segment(id, src, positionUs * src.sampleRate / 1e6)
    }

    fun startAt(id: Int, atNanos: Long) = schedule(Command.Start(id, atNanos))

    fun pauseAt(id: Int, atNanos: Long, seekToUs: Long?) = schedule(Command.Pause(id, atNanos, seekToUs))

    private fun schedule(c: Command) {
        commands.add(c)
        commands.sortBy { it.atNanos }
    }

    fun setVolume(v: Float) {
        volumeTarget = v.coerceIn(0f, 1f)
    }

    fun setRole(role: String) {
        mix = ChannelRoles.matrix(role)
    }

    /** Drops every segment and command (output continues as silence). */
    fun stop() {
        active?.src?.close()
        active = null
        for (s in standby.values) s.src.close()
        standby.clear()
        commands.clear()
    }

    // ------------------------------------------------------------ output

    /**
     * Fills [out] with [frames] interleaved stereo frames (PCM 16) for
     * output frames `firstFrame until firstFrame + frames`.
     */
    fun render(out: ShortArray, frames: Int, firstFrame: Long, clock: OutputClock) {
        if (mixBuf.size < frames * 2) mixBuf = FloatArray(frames * 2)
        var f = 0
        while (f < frames) {
            val abs = firstFrame + f
            val next = commands.firstOrNull()
            val due = if (next != null && clock.valid) clock.frameAt(next.atNanos) else null
            if (next != null && due != null && due <= abs) {
                commands.removeAt(0)
                execute(next, abs, abs - due, clock)
                continue
            }
            val until = if (due != null) min(frames.toLong(), due - firstFrame).toInt() else frames
            renderSpan(f, until - f, abs, due, clock)
            f = until
        }
        for (i in 0 until frames * 2) {
            val v = (mixBuf[i] * 32767f).coerceIn(-32768f, 32767f)
            out[i] = v.toInt().toShort()
        }
    }

    private fun execute(c: Command, at: Long, lateFrames: Long, clock: OutputClock) {
        when (c) {
            is Command.Start -> {
                val seg = standby.remove(c.segment) ?: active?.takeIf { it.id == c.segment }
                if (seg == null) {
                    emit("error", c.segment, clock.nanosAt(at), "segment ${c.segment} is not prepared")
                    return
                }
                val old = active
                if (old != null && old !== seg) old.src.close()
                // Late by `lateFrames` output frames: skip the content that
                // should have been heard meanwhile.
                seg.pos += lateFrames * stepFor(seg)
                seg.playing = true
                seg.ended = false
                seg.startedAt = at
                active = seg
                emit("playCalled", seg.id, clock.nanosAt(at), if (lateFrames > 0) "late by $lateFrames frames" else null)
            }
            is Command.Pause -> {
                val a = active
                if (a == null || a.id != c.segment) return
                a.playing = false
                if (c.seekToUs != null) a.pos = c.seekToUs * a.src.sampleRate / 1e6
                emit("paused", a.id, clock.nanosAt(at), null)
            }
        }
    }

    private fun stepFor(s: Segment) = s.src.sampleRate.toDouble() / outRate * rate

    /**
     * Renders [n] frames starting at buffer frame [offset] (output frame
     * [abs]); [nextDue] is the frame of the next command, faded towards.
     */
    private fun renderSpan(offset: Int, n: Int, abs: Long, nextDue: Long?, clock: OutputClock) {
        if (n <= 0) return
        val a = active
        if (a == null || !a.playing || a.ended) {
            java.util.Arrays.fill(mixBuf, offset * 2, (offset + n) * 2, 0f)
            content.add(abs, n, -1, 0.0, 0.0)
            return
        }
        val step = stepFor(a)
        val startPos = a.pos
        a.pos = resampler.render(a.src, startPos, step, mix, mixBuf, offset * 2, n)
        content.add(abs, n, a.id, startPos, step)
        // Gains: volume ramp (≈10 ms), fade in after a start, fade out
        // before the next switch or pause.
        val switchAhead = nextDue != null && commands.firstOrNull()?.let { affectsActive(it, a) } == true
        val volStep = 1f / max(1, outRate / 100)
        for (i in 0 until n) {
            val frame = abs + i
            volume += (volumeTarget - volume).coerceIn(-volStep, volStep)
            var g = volume
            // Linear ramps that never hit zero on a content frame: the start
            // frame itself is already audible (onsets stay on their frame).
            val sinceStart = frame - a.startedAt
            if (sinceStart in 0 until fade) g *= (sinceStart + 1).toFloat() / fade
            if (switchAhead) {
                val left = nextDue!! - frame
                if (left < fade) g *= max(0L, left).toFloat() / fade
            }
            mixBuf[(offset + i) * 2] *= g
            mixBuf[(offset + i) * 2 + 1] *= g
        }
        if (a.pos >= a.src.frames) {
            a.ended = true
            a.playing = false
            emit("ended", a.id, clock.nanosAt(abs + n), null)
        }
    }

    private fun affectsActive(c: Command, a: Segment) = when (c) {
        is Command.Start -> c.segment != a.id || !a.playing
        is Command.Pause -> c.segment == a.id
    }

    // ---------------------------------------------------------- position

    data class Sample(val segment: Int, val positionUs: Long, val atNanos: Long, val playing: Boolean)

    /**
     * What is being heard at [nowNanos]: the active segment's position, from
     * the content written at the frame the clock says is audible now. Null
     * when nothing is active.
     */
    fun sample(nowNanos: Long, clock: OutputClock): Sample? {
        val a = active ?: return null
        if (!clock.valid) return null
        val heard = clock.frameHeardAt(nowNanos)
        val written = content.end()
        val pos = content.at(heard)
        return when {
            pos != null && pos.segment == a.id ->
                Sample(a.id, (pos.srcFrame * 1e6 / a.src.sampleRate).roundToLong(), nowNanos, a.playing)
            written != null && heard >= written ->
                // Asked about a frame not written yet (clock ahead of the
                // writer): report the write position at its own time.
                Sample(a.id, (a.pos * 1e6 / a.src.sampleRate).roundToLong(), clock.nanosAt(written), a.playing)
            else ->
                // Paused / just started / silence: the position waiting to be heard.
                Sample(a.id, (a.pos * 1e6 / a.src.sampleRate).roundToLong(), nowNanos, false)
        }
    }
}
