package dev.syncsphere.syncsphere_audio.render

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/**
 * Decoded audio the precise renderer reads from: interleaved samples as
 * floats in [-1, 1]. Frames outside `0 until frames` read as silence.
 */
interface PcmSource : AutoCloseable {
    val sampleRate: Int
    val channels: Int
    val frames: Long

    /**
     * Reads [count] frames starting at [frame] into [dst] (interleaved,
     * [channels] values per frame) at [dstOffset]. Frames before 0 or past
     * the end are written as zeros.
     */
    fun read(frame: Long, dst: FloatArray, dstOffset: Int, count: Int)

    override fun close() {}
}

/** In-memory source, for tests and generated audio. */
class ArrayPcmSource(
    override val sampleRate: Int,
    override val channels: Int,
    private val samples: FloatArray,
) : PcmSource {
    override val frames: Long = (samples.size / channels).toLong()

    override fun read(frame: Long, dst: FloatArray, dstOffset: Int, count: Int) {
        for (i in 0 until count) {
            val f = frame + i
            for (c in 0 until channels) {
                dst[dstOffset + i * channels + c] =
                    if (f < 0 || f >= frames) 0f else samples[(f * channels + c).toInt()]
            }
        }
    }
}

/** Layout of a 16-bit PCM WAV file. */
data class WavFormat(val sampleRate: Int, val channels: Int, val dataOffset: Long, val dataBytes: Long) {
    val frames: Long get() = dataBytes / (2L * channels)

    companion object {
        private const val PCM = 1
        private const val EXTENSIBLE = 0xFFFE

        /**
         * Parses the RIFF header (any chunk order, odd-size padding,
         * WAVE_FORMAT_EXTENSIBLE). [fileSize] bounds a data chunk whose
         * declared size is missing or too large (streamed files).
         */
        fun parse(header: ByteBuffer, fileSize: Long): WavFormat {
            val b = header.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            fun tag(): String {
                val a = ByteArray(4)
                b.get(a)
                return String(a, Charsets.US_ASCII)
            }
            if (b.remaining() < 12 || tag() != "RIFF") throw IOException("not a RIFF file")
            b.getInt()
            if (tag() != "WAVE") throw IOException("not a WAVE file")
            var rate = 0
            var channels = 0
            var bits = 0
            var format = 0
            while (b.remaining() >= 8) {
                val id = tag()
                val size = b.getInt().toLong() and 0xFFFFFFFFL
                val bodyStart = b.position()
                when (id) {
                    "fmt " -> {
                        if (size < 16 || b.remaining() < 16) throw IOException("short fmt chunk")
                        format = b.getShort().toInt() and 0xFFFF
                        channels = b.getShort().toInt() and 0xFFFF
                        rate = b.getInt()
                        b.getInt() // byte rate
                        b.getShort() // block align
                        bits = b.getShort().toInt() and 0xFFFF
                        if (format == EXTENSIBLE && size >= 40 && b.remaining() >= 24) {
                            b.getShort() // cbSize
                            b.getShort() // valid bits
                            b.getInt() // channel mask
                            format = b.getShort().toInt() and 0xFFFF // sub-format GUID starts with the format code
                        }
                    }
                    "data" -> {
                        if (format != PCM || bits != 16) throw IOException("unsupported WAV: format $format, $bits bit (need 16-bit PCM)")
                        if (channels !in 1..8 || rate !in 8000..384000) throw IOException("unsupported WAV: $channels ch at $rate Hz")
                        val offset = bodyStart.toLong()
                        val available = (fileSize - offset).coerceAtLeast(0)
                        val bytes = if (size == 0L || size > available) available else size
                        return WavFormat(rate, channels, offset, bytes - bytes % (2L * channels))
                    }
                }
                val next = bodyStart + size + (size and 1L)
                if (next > b.limit()) break
                b.position(next.toInt())
            }
            throw IOException("no data chunk in the first ${header.limit()} bytes")
        }
    }
}

/**
 * A 16-bit PCM WAV file read with positional reads (no shared file
 * pointer, so reads are safe from the render thread while the file stays
 * open). Decoded copies come from `TrackTranscoder`.
 */
class WavFileSource private constructor(
    private val raf: RandomAccessFile,
    private val format: WavFormat,
) : PcmSource {
    override val sampleRate = format.sampleRate
    override val channels = format.channels
    override val frames = format.frames
    private val channel: FileChannel = raf.channel
    private var buf: ByteBuffer = ByteBuffer.allocateDirect(0).order(ByteOrder.LITTLE_ENDIAN)

    override fun read(frame: Long, dst: FloatArray, dstOffset: Int, count: Int) {
        java.util.Arrays.fill(dst, dstOffset, dstOffset + count * channels, 0f)
        val first = maxOf(frame, 0L)
        val last = minOf(frame + count, frames) // exclusive
        if (last <= first) return
        val n = (last - first).toInt()
        val bytes = n * channels * 2
        if (buf.capacity() < bytes) buf = ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN)
        buf.clear()
        buf.limit(bytes)
        var pos = format.dataOffset + first * channels * 2
        while (buf.hasRemaining()) {
            val r = channel.read(buf, pos)
            if (r < 0) break // truncated file: the rest stays silent
            pos += r
        }
        buf.flip()
        val shorts = buf.asShortBuffer()
        var o = dstOffset + ((first - frame).toInt()) * channels
        while (shorts.hasRemaining()) dst[o++] = shorts.get() / 32768f
    }

    override fun close() = raf.close()

    companion object {
        fun open(file: File): WavFileSource {
            val raf = RandomAccessFile(file, "r")
            try {
                val head = ByteBuffer.allocate(minOf(raf.length(), 64 * 1024L).toInt())
                raf.channel.read(head, 0)
                head.flip()
                return WavFileSource(raf, WavFormat.parse(head, raf.length()))
            } catch (e: Exception) {
                raf.close()
                throw e
            }
        }
    }
}
