package dev.syncsphere.syncsphere_audio

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/**
 * Channel roles: each phone (usually one loudspeaker) plays one point of a
 * stereo or surround layout.
 *
 * Stereo sources: left/right pick one channel, mono and center mix both,
 * and the rear surround roles get the passive-matrix difference signal
 * 0.354·(L−R) (0.707·(L−R) at −3 dB), which carries the ambience of most
 * stereo recordings. 5.1 sources (FL, FR, C, LFE, SL, SR) play their
 * matching channel; front phones also take some of the center and LFE so
 * nothing is lost when there is no center phone.
 *
 * Coefficients are row-major [input * outputCount + output]; every role
 * outputs the same signal on both outputs. Negative coefficients are needed
 * for L−R, which Media3's ChannelMixingMatrix does not accept, hence the
 * small [ChannelRoleProcessor].
 */
object ChannelRoleMixing {
    private const val SURROUND = 0.354f

    /** 2×2 coefficients for a stereo source. */
    fun stereoCoefficients(role: String): FloatArray = when (role) {
        "left" -> floatArrayOf(1f, 1f, 0f, 0f)
        "right" -> floatArrayOf(0f, 0f, 1f, 1f)
        "mono", "center" -> floatArrayOf(0.5f, 0.5f, 0.5f, 0.5f)
        "surroundLeft", "surroundRight" -> floatArrayOf(SURROUND, SURROUND, -SURROUND, -SURROUND)
        else -> floatArrayOf(1f, 0f, 0f, 1f)
    }

    /** 6×2 coefficients for a 5.1 source (FL, FR, C, LFE, SL, SR). */
    fun fiveOneCoefficients(role: String): FloatArray {
        // Weight per input channel, same on both outputs.
        val w = when (role) {
            "left" -> floatArrayOf(0.75f, 0f, 0.5f, 0.35f, 0f, 0f)
            "right" -> floatArrayOf(0f, 0.75f, 0.5f, 0.35f, 0f, 0f)
            "center" -> floatArrayOf(0f, 0f, 0.8f, 0.3f, 0f, 0f)
            "surroundLeft" -> floatArrayOf(0f, 0f, 0f, 0f, 0.9f, 0f)
            "surroundRight" -> floatArrayOf(0f, 0f, 0f, 0f, 0f, 0.9f)
            "mono" -> floatArrayOf(0.3f, 0.3f, 0.3f, 0.2f, 0.3f, 0.3f)
            // Stereo: standard 5.1 → 2.0 downmix.
            else -> return floatArrayOf(
                0.5f, 0f, 0f, 0.5f, 0.35f, 0.35f, 0.25f, 0.25f, 0.35f, 0f, 0f, 0.35f,
            )
        }
        return FloatArray(12) { i -> w[i / 2] }
    }

    /** Matrix for [channels] input channels, or null to leave the audio untouched. */
    fun coefficientsFor(role: String, channels: Int): FloatArray? = when {
        role == "stereo" -> null
        channels == 2 -> stereoCoefficients(role)
        channels == 6 -> fiveOneCoefficients(role)
        else -> null
    }

    fun identityCoefficients(channels: Int): FloatArray =
        FloatArray(channels * channels) { i -> if (i / channels == i % channels) 1f else 0f }
}

/**
 * Applies a [ChannelRoleMixing] matrix (any coefficients, including
 * negative ones) to 16-bit or float PCM, producing two channels. Inactive
 * for inputs the role does not change.
 */
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
class ChannelRoleProcessor(private val role: String) : BaseAudioProcessor() {
    private var matrix: FloatArray? = null
    private var inChannels = 0

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        val enc = inputAudioFormat.encoding
        if (enc != C.ENCODING_PCM_16BIT && enc != C.ENCODING_PCM_FLOAT) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        val m = ChannelRoleMixing.coefficientsFor(role, inputAudioFormat.channelCount) ?: return AudioProcessor.AudioFormat.NOT_SET
        matrix = m
        inChannels = inputAudioFormat.channelCount
        return AudioProcessor.AudioFormat(inputAudioFormat.sampleRate, 2, enc)
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val m = matrix ?: return
        val isFloat = inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT
        val bytes = if (isFloat) 4 else 2
        val frames = inputBuffer.remaining() / (bytes * inChannels)
        val out = replaceOutputBuffer(frames * 2 * bytes)
        val frame = FloatArray(inChannels)
        for (f in 0 until frames) {
            for (c in 0 until inChannels) {
                frame[c] = if (isFloat) inputBuffer.float else inputBuffer.short / 32768f
            }
            for (o in 0 until 2) {
                var v = 0f
                for (c in 0 until inChannels) v += frame[c] * m[c * 2 + o]
                v = v.coerceIn(-1f, 1f)
                // ×32768 and rounding: a single routed channel comes out bit-exact.
                if (isFloat) out.putFloat(v) else out.putShort((v * 32768f).roundToInt().coerceIn(-32768, 32767).toShort())
            }
        }
        inputBuffer.position(inputBuffer.limit())
        out.flip()
    }
}

/** Renderers factory whose audio sink applies a channel role. */
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
class RoleRenderersFactory(context: Context, private val role: String) : DefaultRenderersFactory(context) {
    override fun buildAudioSink(
        context: Context,
        enableFloatOutput: Boolean,
        enableAudioOutputPlaybackParams: Boolean,
    ): AudioSink? {
        if (role == "stereo") return super.buildAudioSink(context, enableFloatOutput, enableAudioOutputPlaybackParams)
        // Same as the default sink plus the mixer (Media3 still appends its
        // silence-skipping and Sonic speed processors after custom ones, so
        // rate correction keeps working).
        return DefaultAudioSink.Builder(context)
            .setEnableFloatOutput(enableFloatOutput)
            .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParams)
            .setAudioProcessors(arrayOf<AudioProcessor>(ChannelRoleProcessor(role)))
            .build()
    }
}
