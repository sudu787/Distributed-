package dev.syncsphere.syncsphere_audio.render

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private const val RATE = 48000

/** Frame k of channel c holds a recognisable value (k+1)/1e6 (± by channel). */
private fun rampSource(frames: Int, channels: Int = 2, rate: Int = RATE): ArrayPcmSource {
    val s = FloatArray(frames * channels)
    for (k in 0 until frames) for (c in 0 until channels) s[k * channels + c] = (k + 1) / 1e6f * (if (c == 0) 1 else -1)
    return ArrayPcmSource(rate, channels, s)
}

private fun clockAt(frame0Nanos: Long = 1_000_000_000L) = OutputClock(RATE).apply { update(0, frame0Nanos) }

private fun nanosOfFrame(clock: OutputClock, frame: Long) = clock.nanosAt(frame)

private class Harness(val core: RenderCore, val clock: OutputClock) {
    var next = 0L
    val left = ArrayList<Short>()
    fun run(frames: Int, chunk: Int = 480) {
        val buf = ShortArray(chunk * 2)
        var done = 0
        while (done < frames) {
            core.render(buf, chunk, next, clock)
            for (i in 0 until chunk) left.add(buf[2 * i])
            next += chunk
            done += chunk
        }
    }
    /** First output frame whose left sample is non-zero. */
    fun firstSound(from: Int = 0): Int = (from until left.size).first { left[it].toInt() != 0 }
}

class RenderCoreTest {
    private val events = ArrayList<Triple<String, Int, Long>>()
    private fun core() = RenderCore(RATE) { k, s, at, _ -> events.add(Triple(k, s, at)) }

    @Test
    fun startLandsOnTheExactOutputFrame() {
        for (target in listOf(1000L, 4321L, 9599L)) {
            events.clear()
            val clock = clockAt()
            val core = core()
            val h = Harness(core, clock)
            core.prepare(1, ArrayPcmSource(RATE, 1, FloatArray(RATE) { 0.5f }), 0)
            core.startAt(1, nanosOfFrame(clock, target))
            h.run(12000)
            assertEquals(target.toInt(), h.firstSound(), "content must begin on frame $target")
            val started = events.single { it.first == "playCalled" }
            assertEquals(nanosOfFrame(clock, target), started.third)
        }
    }

    @Test
    fun lateStartSkipsContentAndStaysAligned() {
        val clock = clockAt()
        val core = core()
        val h = Harness(core, clock)
        h.run(4800) // 100 ms of silence already written
        core.prepare(7, rampSource(RATE), 0)
        core.startAt(7, nanosOfFrame(clock, 2400)) // was due 50 ms ago
        h.run(480)
        // At output frame 4800 + k we must hear source frame 2400 + k (value
        // (2401 + k)e-6 · 32767); k past the fade-in.
        val k = 200
        val expected = ((2401 + k) / 1e6f * 32767f).toInt().toShort()
        assertEquals(expected, h.left[4800 + k])
        val pos = core.content.at(4800)
        assertNotNull(pos)
        assertEquals(2400.0, pos.srcFrame, 1e-9)
    }

    @Test
    fun startAtAPositionReadsFromThere() {
        val clock = clockAt()
        val core = core()
        val h = Harness(core, clock)
        core.prepare(1, rampSource(RATE * 2), 500_000) // 0.5 s = frame 24000
        core.startAt(1, nanosOfFrame(clock, 960))
        h.run(1920)
        val p = core.content.at(960 + 100)!!
        assertEquals(24100.0, p.srcFrame, 1e-9)
    }

    @Test
    fun pauseStopsOnItsFrameAndSeeks() {
        val clock = clockAt()
        val core = core()
        val h = Harness(core, clock)
        core.prepare(1, ArrayPcmSource(RATE, 1, FloatArray(RATE * 2) { 0.5f }), 0)
        core.startAt(1, nanosOfFrame(clock, 0))
        core.pauseAt(1, nanosOfFrame(clock, 9600), 1_000_000)
        h.run(14400)
        assertTrue(h.left[9599 - RenderCore.FADE_MS * RATE / 1000 - 1].toInt() != 0)
        assertEquals(0, h.left[9600].toInt())
        assertEquals(0, h.left[14000].toInt())
        assertTrue(events.any { it.first == "paused" && it.third == nanosOfFrame(clock, 9600) })
        // Resume continues at the seek position.
        core.startAt(1, nanosOfFrame(clock, 14400 + 480))
        h.run(1920)
        assertEquals(RATE.toDouble() + 100, core.content.at(14400 + 480 + 100)!!.srcFrame, 1e-9)
    }

    @Test
    fun switchFadesOutOldAndFadesInNew() {
        val clock = clockAt()
        val core = core()
        val h = Harness(core, clock)
        val fade = RATE * RenderCore.FADE_MS / 1000
        core.prepare(1, ArrayPcmSource(RATE, 1, FloatArray(RATE) { 0.5f }), 0)
        core.startAt(1, nanosOfFrame(clock, 0))
        h.run(4800)
        core.prepare(2, ArrayPcmSource(RATE, 1, FloatArray(RATE) { 0.5f }), 0)
        core.startAt(2, nanosOfFrame(clock, 9600))
        h.run(9600)
        val full = (0.5f * 32767f).toInt()
        assertTrue(h.left[9600 - fade / 2] < full, "old segment fades out before the switch")
        assertTrue(h.left[9599] <= full / fade + 1, "old segment is silent on the frame before the switch")
        assertTrue(h.left[9600 + fade / 2] < full, "new segment fades in")
        assertEquals(full, h.left[9600 + fade + 10].toInt())
        assertEquals(2, core.activeSegment)
    }

    @Test
    fun rateChangeIsTrackedExactly() {
        val clock = clockAt()
        val core = core()
        val h = Harness(core, clock)
        core.prepare(1, rampSource(RATE * 3), 0)
        core.startAt(1, nanosOfFrame(clock, 0))
        h.run(4800)
        core.rate = 1.003
        h.run(48000)
        val p = core.content.at(4800 + 48000 - 1)!!
        assertEquals(4800 + 48000 * 1.003 - 1.003, p.srcFrame, 1e-6)
        val s = core.sample(clock.nanosAt(30000), clock)!!
        assertEquals(1, s.segment)
        // frame 30000 → src 4800 + 25200·1.003
        assertTrue(abs(((4800 + 25200 * 1.003) * 1e6 / RATE).toLong() - s.positionUs) <= 2)
    }

    @Test
    fun resamples44100To48000AtTheRightPace() {
        val clock = clockAt()
        val core = core()
        val h = Harness(core, clock)
        val src = ArrayPcmSource(44100, 1, FloatArray(44100 * 2) { i -> sin(2 * Math.PI * 441 * i / 44100).toFloat() * 0.5f })
        core.prepare(1, src, 0)
        core.startAt(1, nanosOfFrame(clock, 0))
        h.run(48000)
        // One second of output consumed one second of source.
        assertEquals(44100.0, core.content.at(48000 - 1)!!.srcFrame + 44100.0 / 48000, 1e-6)
        // The 441 Hz tone survives interpolation: compare with the ideal value.
        var maxErr = 0f
        for (k in 1000 until 2000) {
            val ideal = sin(2 * Math.PI * 441 * k / 48000.0).toFloat() * 0.5f * 32767f
            maxErr = maxOf(maxErr, abs(h.left[k] - ideal))
        }
        assertTrue(maxErr < 40f, "interpolation error $maxErr")
    }

    @Test
    fun channelRolesAndMonoSources() {
        val clock = clockAt()
        val core = core()
        val buf = ShortArray(480 * 2)
        core.prepare(1, rampSource(RATE), 0)
        core.setRole("right")
        core.startAt(1, nanosOfFrame(clock, 0))
        core.render(buf, 480, 0, clock)
        val k = 300 // past the fade-in
        val right = (-(k + 1) / 1e6f * 32767f).toInt().toShort()
        assertEquals(right, buf[2 * k])
        assertEquals(right, buf[2 * k + 1])
    }

    @Test
    fun endOfTrackGoesSilentAndReportsEnded() {
        val clock = clockAt()
        val core = core()
        val h = Harness(core, clock)
        core.prepare(3, ArrayPcmSource(RATE, 1, FloatArray(1000) { 0.5f }), 0)
        core.startAt(3, nanosOfFrame(clock, 0))
        h.run(4800)
        assertEquals(0, h.left[2000].toInt())
        assertTrue(events.any { it.first == "ended" && it.second == 3 })
    }

    @Test
    fun unpreparedStartIsAnErrorNotACrash() {
        val clock = clockAt()
        val core = core()
        core.startAt(42, nanosOfFrame(clock, 10))
        Harness(core, clock).run(480)
        assertTrue(events.any { it.first == "error" && it.second == 42 })
        assertNull(core.activeSegment)
    }

    @Test
    fun sampleReportsWhatIsHeardNow() {
        val clock = clockAt()
        val core = core()
        val h = Harness(core, clock)
        core.prepare(1, rampSource(RATE * 2), 0)
        core.startAt(1, nanosOfFrame(clock, 4800))
        h.run(24000)
        val now = clock.nanosAt(14800)
        val s = core.sample(now, clock)!!
        assertEquals(now, s.atNanos)
        assertTrue(abs(10000L * 1_000_000 / RATE - s.positionUs) <= 1)
        assertTrue(s.playing)
    }
}

class OutputClockTest {
    @Test
    fun mapsFramesAndTimes() {
        val c = OutputClock(48000)
        c.update(48000, 2_000_000_000L)
        assertEquals(2_500_000_000L, c.nanosAt(72000))
        assertEquals(72000L, c.frameAt(2_500_000_000L))
        assertEquals(71999L, c.frameHeardAt(2_499_990_000L))
        // A frame's own time maps back to that frame despite ns truncation.
        for (f in listOf(1L, 7L, 48001L, 99_999L)) {
            assertEquals(f, c.frameAt(c.nanosAt(f)))
            assertEquals(f, c.frameHeardAt(c.nanosAt(f)))
        }
    }

    @Test
    fun rejectsImplausibleTimestampsButFollowsARouteChange() {
        val c = OutputClock(48000)
        assertTrue(c.update(0, 1_000_000_000L))
        assertTrue(c.update(48000, 2_000_000_000L))
        // 5 % too fast: rejected...
        for (i in 1 until OutputClock.REANCHOR_AFTER) assertTrue(!c.update(48000 + 50400L * i, 2_000_000_000L + 1_000_000_000L * i))
        // ...until it persists.
        assertTrue(c.update(48000 + 50400L * 5, 7_000_000_000L))
        assertTrue(!c.update(10, 7_100_000_000L).also { }, "frames never go back")
    }

    @Test
    fun estimateIsReplacedByTheFirstTimestamp() {
        val c = OutputClock(48000)
        c.estimate(0, 1_000_000_000L, 40_000_000L)
        assertTrue(c.valid && !c.fromTimestamp)
        c.update(4800, 1_150_000_000L)
        assertTrue(c.fromTimestamp)
        c.estimate(0, 0, 0) // ignored now
        assertEquals(1_150_000_000L, c.nanosAt(4800))
    }
}

class ContentMapTest {
    @Test
    fun mergesContiguousSpansAndAnswersBySegment() {
        val m = ContentMap()
        m.add(0, 480, -1, 0.0, 0.0)
        m.add(480, 480, 1, 0.0, 1.0)
        m.add(960, 480, 1, 480.0, 1.0)
        m.add(1440, 480, 1, 960.0, 1.002)
        assertNull(m.at(100))
        assertEquals(700.0, m.at(1180)!!.srcFrame, 1e-9)
        assertEquals(960.0 + 10 * 1.002, m.at(1450)!!.srcFrame, 1e-9)
        assertNull(m.at(1920), "not written yet")
        assertEquals(1920L, m.end())
    }
}

class WavFormatTest {
    private fun wav(channels: Int, rate: Int, frames: Int, extraChunk: Boolean = false): ByteArray {
        val data = frames * channels * 2
        val extra = if (extraChunk) 8 + 5 + 1 else 0
        val b = ByteBuffer.allocate(44 + extra + data).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(36 + extra + data).put("WAVE".toByteArray())
        if (extraChunk) b.put("LIST".toByteArray()).putInt(5).put(ByteArray(6)) // odd size + pad
        b.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(channels.toShort()).putInt(rate)
            .putInt(rate * channels * 2).putShort((channels * 2).toShort()).putShort(16)
        b.put("data".toByteArray()).putInt(data)
        for (i in 0 until frames * channels) b.putShort((i % 1000).toShort())
        return b.array()
    }

    @Test
    fun parsesCanonicalAndChunkedHeaders() {
        val f = WavFormat.parse(ByteBuffer.wrap(wav(2, 44100, 100)), 44L + 400)
        assertEquals(WavFormat(44100, 2, 44, 400), f)
        val g = WavFormat.parse(ByteBuffer.wrap(wav(1, 48000, 10, extraChunk = true)), 44L + 14 + 20)
        assertEquals(1, g.channels)
        assertEquals(10L, g.frames)
    }

    @Test
    fun rejectsWhatTheRendererCannotPlay() {
        val bytes = wav(2, 44100, 4)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).putShort(34, 24)
        assertFailsWith<java.io.IOException> { WavFormat.parse(ByteBuffer.wrap(bytes), bytes.size.toLong()) }
        assertFailsWith<java.io.IOException> { WavFormat.parse(ByteBuffer.wrap("hello world!".toByteArray()), 12) }
    }

    @Test
    fun fileSourceReadsSamplesAndPadsWithSilence() {
        val file = File.createTempFile("syncsphere-test", ".wav")
        try {
            file.writeBytes(wav(2, 48000, 100))
            WavFileSource.open(file).use { src ->
                assertEquals(100L, src.frames)
                val dst = FloatArray(10 * 2)
                src.read(95, dst, 0, 10)
                assertEquals(190 / 32768f, dst[0], 1e-9f) // frame 95, left = sample index 190
                assertEquals(0f, dst[2 * 5], "past the end is silence")
                src.read(-2, dst, 0, 3)
                assertEquals(0f, dst[0])
                assertEquals(0f, dst[2 * 2])
                assertEquals(1 / 32768f, dst[2 * 2 + 1], 1e-9f) // frame 0 right
            }
        } finally {
            file.delete()
        }
    }
}
