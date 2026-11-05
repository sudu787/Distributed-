package dev.syncsphere.syncsphere_audio.render

import kotlin.math.floor

/**
 * Reads a [PcmSource] at a fractional position and step (source frames per
 * output frame) into stereo, with cubic Hermite (Catmull-Rom) interpolation.
 * A step of exactly 1 at an integral position copies samples unchanged.
 *
 * Channel mapping to stereo: mono → both sides; stereo through [mix]
 * (row-major in×out, see [ChannelRoles]); more channels: the first two.
 */
class Resampler {
    private var scratch = FloatArray(0)

    /**
     * Renders [frames] stereo frames into [out] at [outOffset] (interleaved
     * L,R), reading [src] from [pos] in steps of [step]. Returns the source
     * position after the last frame.
     */
    fun render(src: PcmSource, pos: Double, step: Double, mix: FloatArray, out: FloatArray, outOffset: Int, frames: Int): Double {
        if (frames <= 0) return pos
        val ch = src.channels
        val first = floor(pos).toLong() - 1
        val lastPos = pos + step * (frames - 1)
        val count = (floor(lastPos).toLong() + 3 - first).toInt()
        if (scratch.size < count * ch) scratch = FloatArray(count * ch)
        src.read(first, scratch, 0, count)
        val exact = step == 1.0 && pos == floor(pos)
        var p = pos
        for (i in 0 until frames) {
            val base = floor(p).toLong()
            val idx = (base - first).toInt() // frame index of `base` in scratch
            val t = (p - base).toFloat()
            var l: Float
            var r: Float
            if (exact || t == 0f) {
                l = sample(idx, 0, ch)
                r = if (ch == 1) l else sample(idx, 1, ch)
            } else {
                l = hermite(idx, 0, ch, t)
                r = if (ch == 1) l else hermite(idx, 1, ch, t)
            }
            if (ch == 2) {
                val ml = l * mix[0] + r * mix[2]
                val mr = l * mix[1] + r * mix[3]
                l = ml
                r = mr
            }
            out[outOffset + 2 * i] = l
            out[outOffset + 2 * i + 1] = r
            p = pos + step * (i + 1)
        }
        return p
    }

    private fun sample(frame: Int, c: Int, ch: Int) = scratch[frame * ch + c]

    private fun hermite(i: Int, c: Int, ch: Int, t: Float): Float {
        val y0 = sample(i - 1, c, ch)
        val y1 = sample(i, c, ch)
        val y2 = sample(i + 1, c, ch)
        val y3 = sample(i + 2, c, ch)
        val c1 = 0.5f * (y2 - y0)
        val c2 = y0 - 2.5f * y1 + 2f * y2 - 0.5f * y3
        val c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2)
        return ((c3 * t + c2) * t + c1) * t + y1
    }
}

/** Distributed-stereo channel roles as 2×2 mixing matrices (row-major in×out). */
object ChannelRoles {
    fun matrix(role: String): FloatArray = when (role) {
        "left" -> floatArrayOf(1f, 1f, 0f, 0f)
        "right" -> floatArrayOf(0f, 0f, 1f, 1f)
        "mono" -> floatArrayOf(0.5f, 0.5f, 0.5f, 0.5f)
        else -> floatArrayOf(1f, 0f, 0f, 1f)
    }
}
