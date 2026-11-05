package dev.syncsphere.syncsphere_audio.render

import kotlin.math.abs
import kotlin.math.floor

/**
 * Maps output frames (the index of each frame written to the AudioTrack) to
 * the `System.nanoTime()` at which that frame is heard, from
 * `AudioTrack.getTimestamp` (frame F was presented at time t).
 *
 * Timestamps are checked before use: the frame position must not go back,
 * and the rate implied by two timestamps must be near the nominal rate. A
 * route change (e.g. headphones plugged in) legitimately breaks that; after
 * [REANCHOR_AFTER] consecutive rejections the clock re-anchors.
 *
 * Before the first hardware timestamp, [estimate] gives a coarse mapping
 * (head position plus a latency guess); [fromTimestamp] tells which one is
 * in use.
 */
class OutputClock(val sampleRate: Int) {
    companion object {
        const val REANCHOR_AFTER = 5

        /** Largest accepted deviation of the implied rate from nominal. */
        const val MAX_RATE_ERROR = 0.01

        /** Timestamps closer together than this are not rate-checked. */
        const val MIN_CHECK_SPAN_NS = 100_000_000L

        /**
         * Times are whole nanoseconds, so [nanosAt] of a frame can land up to
         * 1 ns early; this tolerance (≈2 ns at 48 kHz) keeps a frame's own
         * time mapping back to that frame.
         */
        private const val EPS_FRAMES = 1e-4
    }

    private var anchorFrame = 0L
    private var anchorNanos = 0L

    var valid = false
        private set
    var fromTimestamp = false
        private set
    var rejected = 0
        private set

    /** Total timestamps accepted and rejected (diagnostics). */
    var accepted = 0L
        private set
    var rejectedTotal = 0L
        private set

    /** Accepts a hardware timestamp. Returns false if it was rejected. */
    fun update(framePosition: Long, nanoTime: Long): Boolean {
        if (valid && fromTimestamp) {
            val df = framePosition - anchorFrame
            val dt = nanoTime - anchorNanos
            val plausible = df >= 0 && dt >= 0 &&
                (dt < MIN_CHECK_SPAN_NS || abs(df * 1e9 / dt / sampleRate - 1.0) <= MAX_RATE_ERROR)
            if (!plausible && ++rejected < REANCHOR_AFTER) {
                rejectedTotal++
                return false
            }
        }
        anchorFrame = framePosition
        anchorNanos = nanoTime
        valid = true
        fromTimestamp = true
        rejected = 0
        accepted++
        return true
    }

    /**
     * Coarse mapping until hardware timestamps exist: frame
     * [headPosition] (what the mixer consumed) is heard about
     * [latencyNanos] after [nowNanos].
     */
    fun estimate(headPosition: Long, nowNanos: Long, latencyNanos: Long) {
        if (fromTimestamp) return
        anchorFrame = headPosition
        anchorNanos = nowNanos + latencyNanos
        valid = true
    }

    /** When output frame [frame] is (or was) heard. */
    fun nanosAt(frame: Long): Long = anchorNanos + ((frame - anchorFrame) * 1e9 / sampleRate).toLong()

    /** Exact (fractional) output frame heard at [nanos]. */
    fun frameAtExact(nanos: Long): Double = anchorFrame + (nanos - anchorNanos) * sampleRate / 1e9

    /** First output frame heard at or after [nanos]. */
    fun frameAt(nanos: Long): Long = kotlin.math.ceil(frameAtExact(nanos) - EPS_FRAMES).toLong()

    /** Output frame being heard at [nanos] (floor). */
    fun frameHeardAt(nanos: Long): Long = floor(frameAtExact(nanos) + EPS_FRAMES).toLong()
}
