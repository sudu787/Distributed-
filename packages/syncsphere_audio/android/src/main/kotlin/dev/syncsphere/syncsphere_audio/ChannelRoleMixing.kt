package dev.syncsphere.syncsphere_audio

import android.content.Context
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink

/**
 * Experimental distributed stereo: routes one source channel (or a mono
 * mix) of a stereo track to all of this device's outputs. Phones usually
 * have a single loudspeaker, so a "left" phone plays the left channel.
 *
 * Media3's [ChannelMixingAudioProcessor] needs a matrix for every input
 * channel count it may see; non-stereo inputs get identity matrices (the
 * processor is then inactive for them).
 */
object ChannelRoleMixing {
    /** Row-major (input × output) coefficients for a stereo source. */
    fun stereoCoefficients(role: String): FloatArray = when (role) {
        "left" -> floatArrayOf(1f, 1f, 0f, 0f)
        "right" -> floatArrayOf(0f, 0f, 1f, 1f)
        "mono" -> floatArrayOf(0.5f, 0.5f, 0.5f, 0.5f)
        else -> floatArrayOf(1f, 0f, 0f, 1f)
    }

    fun identityCoefficients(channels: Int): FloatArray =
        FloatArray(channels * channels) { i -> if (i / channels == i % channels) 1f else 0f }

    @androidx.annotation.OptIn(markerClass = [UnstableApi::class])
    fun processorFor(role: String): ChannelMixingAudioProcessor {
        val p = ChannelMixingAudioProcessor()
        for (c in 1..8) {
            val coeff = if (c == 2) stereoCoefficients(role) else identityCoefficients(c)
            p.putChannelMixingMatrix(ChannelMixingMatrix(c, c, coeff))
        }
        return p
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
            .setAudioProcessors(arrayOf<AudioProcessor>(ChannelRoleMixing.processorFor(role)))
            .build()
    }
}
