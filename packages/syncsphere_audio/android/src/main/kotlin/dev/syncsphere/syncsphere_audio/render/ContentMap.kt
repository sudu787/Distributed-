package dev.syncsphere.syncsphere_audio.render

/**
 * Remembers what was written at each output frame: which segment, and which
 * (fractional) source frame, so the renderer can report exactly what is
 * being heard now, rate changes included. Spans are appended in output
 * order; old ones are dropped once [capacity] is reached (a few seconds of
 * 10 ms chunks is plenty: the hardware plays at most the buffer behind).
 */
class ContentMap(private val capacity: Int = 1024) {
    /** [segment] < 0 marks silence. */
    data class Span(val outStart: Long, val frames: Int, val segment: Int, val srcStart: Double, val step: Double) {
        val outEnd: Long get() = outStart + frames
    }

    data class Position(val segment: Int, val srcFrame: Double)

    private val spans = ArrayDeque<Span>()

    fun add(outStart: Long, frames: Int, segment: Int, srcStart: Double, step: Double) {
        if (frames <= 0) return
        val last = spans.lastOrNull()
        // Merge contiguous spans of the same playback (keeps the map small).
        if (last != null && last.outEnd == outStart && last.segment == segment &&
            (segment < 0 || (last.step == step && kotlin.math.abs(last.srcStart + last.frames * last.step - srcStart) < 1e-6))
        ) {
            spans.removeLast()
            spans.addLast(last.copy(frames = last.frames + frames))
            return
        }
        spans.addLast(Span(outStart, frames, segment, srcStart, step))
        while (spans.size > capacity) spans.removeFirst()
    }

    /** What was written at output frame [outFrame]; null for silence or unknown. */
    fun at(outFrame: Long): Position? {
        for (i in spans.indices.reversed()) {
            val s = spans[i]
            if (outFrame >= s.outEnd) return null // beyond what was written
            if (outFrame >= s.outStart) {
                return if (s.segment < 0) null else Position(s.segment, s.srcStart + (outFrame - s.outStart) * s.step)
            }
        }
        return null
    }

    /** Last output frame written + 1, or null when empty. */
    fun end(): Long? = spans.lastOrNull()?.outEnd

    fun clear() = spans.clear()
}
