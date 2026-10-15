package dev.syncsphere.syncsphere_audio

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes a compressed track into a 16-bit PCM WAV file.
 *
 * Why: ExoPlayer seeks VBR MP3 through the Xing table of contents (100
 * entries, each quantized to 1/256 of the file), which can land hundreds of
 * milliseconds away from the requested time while still *reporting* the
 * requested time. Every device seeks differently, so after a resume, seek,
 * late join or resync the room drifts apart by an amount no position report
 * reveals. WAV seeking is computed from the byte offset and is sample-exact.
 *
 * All devices use the platform software decoder when available so the
 * decoded samples (including decoder delay) are identical across phones.
 */
object TrackTranscoder {
    private const val TIMEOUT_US = 10_000L
    private const val MAX_DURATION_US = 60L * 60 * 1_000_000 // 1 h

    fun toWav(context: Context, uri: String, out: File): Map<String, Any?> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        val tmp = File(out.parentFile, out.name + ".part")
        try {
            extractor.setDataSource(context, Uri.parse(uri), null)
            val trackIndex = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw IllegalArgumentException("no audio track")
            extractor.selectTrack(trackIndex)
            val inFormat = extractor.getTrackFormat(trackIndex)
            val mime = inFormat.getString(MediaFormat.KEY_MIME)!!
            if (inFormat.containsKey(MediaFormat.KEY_DURATION) &&
                inFormat.getLong(MediaFormat.KEY_DURATION) > MAX_DURATION_US
            ) {
                throw IllegalArgumentException("track longer than 1 h")
            }
            val decoderName = pickDecoder(mime)
            val c = if (decoderName != null) MediaCodec.createByCodecName(decoderName) else MediaCodec.createDecoderByType(mime)
            codec = c
            c.configure(inFormat, null, null, 0)
            c.start()

            out.parentFile?.mkdirs()
            RandomAccessFile(tmp, "rw").use { raf ->
                raf.setLength(0)
                raf.write(ByteArray(44)) // header written at the end
                var sampleRate = inFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                var channels = inFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                var floatPcm = false
                var dataBytes = 0L
                var inputDone = false
                var outputDone = false
                val info = MediaCodec.BufferInfo()
                var scratch = ByteArray(0)
                while (!outputDone) {
                    if (!inputDone) {
                        val i = c.dequeueInputBuffer(TIMEOUT_US)
                        if (i >= 0) {
                            val buf = c.getInputBuffer(i)!!
                            val n = extractor.readSampleData(buf, 0)
                            if (n < 0) {
                                c.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                c.queueInputBuffer(i, 0, n, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val o = c.dequeueOutputBuffer(info, TIMEOUT_US)
                    when {
                        o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val f = c.outputFormat
                            sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            floatPcm = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                                f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                        }
                        o >= 0 -> {
                            val buf = c.getOutputBuffer(o)!!
                            if (info.size > 0) {
                                buf.position(info.offset)
                                buf.limit(info.offset + info.size)
                                val pcm16 = if (floatPcm) floatTo16(buf.slice().order(ByteOrder.nativeOrder())) else null
                                val len = pcm16?.size ?: info.size
                                if (pcm16 != null) {
                                    raf.write(pcm16)
                                } else {
                                    if (scratch.size < len) scratch = ByteArray(len)
                                    buf.get(scratch, 0, len)
                                    raf.write(scratch, 0, len)
                                }
                                dataBytes += len
                            }
                            c.releaseOutputBuffer(o, false)
                            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) outputDone = true
                        }
                    }
                }
                if (dataBytes == 0L) throw IllegalStateException("decoder produced no audio")
                if (dataBytes > 0xFFFFFFFFL - 36) throw IllegalStateException("decoded audio too large for WAV")
                raf.seek(0)
                raf.write(wavHeader(sampleRate, channels, dataBytes))
                val frames = dataBytes / (2L * channels)
                if (!tmp.renameTo(out)) throw IllegalStateException("cannot move decoded file into place")
                return mapOf(
                    "path" to out.absolutePath,
                    "sampleRate" to sampleRate,
                    "channels" to channels,
                    "durationUs" to frames * 1_000_000L / sampleRate,
                    "decoder" to (decoderName ?: "default"),
                )
            }
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            codec?.release()
            extractor.release()
            if (tmp.exists()) tmp.delete()
        }
    }

    /** Prefers the platform software decoder, identical on every device. */
    private fun pickDecoder(mime: String): String? {
        val decoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
        }
        fun isPlatformSoftware(name: String) = name.startsWith("c2.android.") || name.startsWith("OMX.google.")
        return decoders.firstOrNull { isPlatformSoftware(it.name) }?.name
            ?: decoders.firstOrNull { Build.VERSION.SDK_INT >= 29 && it.isSoftwareOnly }?.name
            ?: decoders.firstOrNull()?.name
    }

    private fun floatTo16(src: ByteBuffer): ByteArray {
        val floats = src.asFloatBuffer()
        val out = ByteBuffer.allocate(floats.remaining() * 2).order(ByteOrder.LITTLE_ENDIAN)
        while (floats.hasRemaining()) {
            val v = (floats.get().coerceIn(-1f, 1f) * 32767f).toInt()
            out.putShort(v.toShort())
        }
        return out.array()
    }

    private fun wavHeader(rate: Int, channels: Int, dataBytes: Long): ByteArray {
        val b = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt((36 + dataBytes).toInt()).put("WAVE".toByteArray())
        b.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(channels.toShort())
            .putInt(rate).putInt(rate * channels * 2).putShort((channels * 2).toShort()).putShort(16)
        b.put("data".toByteArray()).putInt(dataBytes.toInt())
        return b.array()
    }
}
