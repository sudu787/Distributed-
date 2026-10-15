package dev.syncsphere.syncsphere_audio

/**
 * Turns several coarse `Player.getCurrentPosition()` readings into one
 * precise (position, time) pair.
 *
 * The player position is reported in whole milliseconds and is refreshed by
 * ExoPlayer's playback thread roughly every 10 ms, so a single reading can lag
 * the true position by up to ~11 ms. Every reading is therefore a *lower
 * bound* on the position at the moment it was taken. Projecting each reading
 * forward to the time of the last one (at the current speed) and taking the
 * maximum keeps the freshest bound; adding half a millisecond compensates the
 * floor rounding on average. With readings spread over more than one refresh
 * period the residual error is typically 1–2 ms.
 *
 * Pure Kotlin so it can be unit-tested on the JVM.
 */
object PositionEstimator {
    /** One reading: position in ms and `System.nanoTime()` when taken. */
    data class Reading(val positionMs: Long, val atNanos: Long)

    data class Estimate(val positionUs: Long, val atNanos: Long)

    fun estimate(readings: List<Reading>, speed: Float, playing: Boolean): Estimate? {
        if (readings.isEmpty()) return null
        val last = readings.last()
        if (!playing) return Estimate(last.positionMs * 1000, last.atNanos)
        var best = Long.MIN_VALUE
        for (r in readings) {
            val projected = r.positionMs * 1000 + ((last.atNanos - r.atNanos) / 1000.0 * speed).toLong()
            if (projected > best) best = projected
        }
        return Estimate(best + 500, last.atNanos)
    }
}
