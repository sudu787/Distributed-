package dev.syncsphere.syncsphere_audio

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PositionEstimatorTest {
    /** Simulates ExoPlayer: position refreshed every 10 ms, floored to ms. */
    private fun reading(trueStartMs: Double, refreshPhaseMs: Double, atMs: Double): PositionEstimator.Reading {
        val lastRefresh = Math.floor((atMs - refreshPhaseMs) / 10.0) * 10.0 + refreshPhaseMs
        val pos = Math.floor(trueStartMs + lastRefresh)
        return PositionEstimator.Reading(pos.toLong(), (atMs * 1_000_000).toLong())
    }

    @Test
    fun recoversPositionWithinTwoMilliseconds() {
        for (phase in listOf(0.0, 2.5, 7.3, 9.9)) {
            val readings = (0 until 7).map { reading(5000.0, phase, 100.0 + it * 2.0) }
            val est = PositionEstimator.estimate(readings, 1f, true)!!
            val truthUs = (5000.0 + 112.0) * 1000
            assertTrue(Math.abs(est.positionUs - truthUs) <= 2000, "phase $phase: ${est.positionUs} vs $truthUs")
        }
    }

    @Test
    fun pausedUsesLastReading() {
        val r = listOf(PositionEstimator.Reading(1234, 10), PositionEstimator.Reading(1234, 20))
        assertEquals(1_234_000, PositionEstimator.estimate(r, 1f, false)!!.positionUs)
    }

    @Test
    fun emptyIsNull() {
        assertNull(PositionEstimator.estimate(emptyList(), 1f, true))
    }
}
