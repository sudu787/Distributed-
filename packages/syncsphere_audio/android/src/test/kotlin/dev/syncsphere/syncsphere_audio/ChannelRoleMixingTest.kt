package dev.syncsphere.syncsphere_audio

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class ChannelRoleMixingTest {
    // Coefficients are indexed [input * outputCount + output].
    private fun mix(coeff: FloatArray, l: Float, r: Float) =
        floatArrayOf(l * coeff[0] + r * coeff[2], l * coeff[1] + r * coeff[3])

    @Test
    fun stereoPassesThrough() {
        assertContentEquals(floatArrayOf(0.2f, 0.8f), mix(ChannelRoleMixing.stereoCoefficients("stereo"), 0.2f, 0.8f))
    }

    @Test
    fun leftAndRightRouteOneChannelToBothOutputs() {
        assertContentEquals(floatArrayOf(0.2f, 0.2f), mix(ChannelRoleMixing.stereoCoefficients("left"), 0.2f, 0.8f))
        assertContentEquals(floatArrayOf(0.8f, 0.8f), mix(ChannelRoleMixing.stereoCoefficients("right"), 0.2f, 0.8f))
    }

    @Test
    fun monoAveragesChannels() {
        assertContentEquals(floatArrayOf(0.5f, 0.5f), mix(ChannelRoleMixing.stereoCoefficients("mono"), 0.2f, 0.8f))
    }

    @Test
    fun unknownRoleFallsBackToStereo() {
        assertContentEquals(ChannelRoleMixing.stereoCoefficients("stereo"), ChannelRoleMixing.stereoCoefficients("bogus"))
    }

    @Test
    fun identityMatrices() {
        assertContentEquals(floatArrayOf(1f), ChannelRoleMixing.identityCoefficients(1))
        assertContentEquals(
            floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f),
            ChannelRoleMixing.identityCoefficients(3),
        )
    }

    private fun mix6(coeff: FloatArray, input: FloatArray) =
        floatArrayOf((0 until 6).sumOf { (input[it] * coeff[it * 2]).toDouble() }.toFloat(),
            (0 until 6).sumOf { (input[it] * coeff[it * 2 + 1]).toDouble() }.toFloat())

    @Test
    fun centerMixesAndSurroundsCarryTheDifference() {
        assertContentEquals(floatArrayOf(0.5f, 0.5f), mix(ChannelRoleMixing.stereoCoefficients("center"), 0.2f, 0.8f))
        val s = mix(ChannelRoleMixing.stereoCoefficients("surroundLeft"), 0.8f, 0.2f)
        assertEquals(0.354f * 0.6f, s[0], 1e-6f)
        assertEquals(s[0], s[1], 0f)
        // Content identical in both channels (a centred voice) is not in the surrounds.
        assertContentEquals(floatArrayOf(0f, 0f), mix(ChannelRoleMixing.stereoCoefficients("surroundRight"), 0.5f, 0.5f))
    }

    @Test
    fun fiveOneSourcesPlayTheMatchingChannel() {
        val x = floatArrayOf(0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f) // FL FR C LFE SL SR
        assertEquals(0.9f * 0.5f, mix6(ChannelRoleMixing.fiveOneCoefficients("surroundLeft"), x)[0], 1e-6f)
        assertEquals(0.9f * 0.6f, mix6(ChannelRoleMixing.fiveOneCoefficients("surroundRight"), x)[1], 1e-6f)
        assertEquals(0.8f * 0.3f + 0.3f * 0.4f, mix6(ChannelRoleMixing.fiveOneCoefficients("center"), x)[0], 1e-6f)
        assertEquals(0.75f * 0.1f + 0.5f * 0.3f + 0.35f * 0.4f, mix6(ChannelRoleMixing.fiveOneCoefficients("left"), x)[1], 1e-6f)
    }

    @Test
    fun stereoRoleAndUnsupportedLayoutsAreLeftAlone() {
        assertNull(ChannelRoleMixing.coefficientsFor("stereo", 2))
        assertNull(ChannelRoleMixing.coefficientsFor("left", 1))
        assertNull(ChannelRoleMixing.coefficientsFor("left", 8))
        assertEquals(12, ChannelRoleMixing.coefficientsFor("center", 6)!!.size)
    }

    /** Runs interleaved 16-bit stereo PCM through the real processor. */
    private fun process(role: String, interleaved: ShortArray): ShortArray? {
        val p = ChannelRoleProcessor(role)
        val fmt = p.configure(AudioProcessor.AudioFormat(44100, 2, C.ENCODING_PCM_16BIT))
        if (!p.isActive) return null
        assertEquals(2, fmt.channelCount)
        @Suppress("DEPRECATION")
        p.flush()
        val buf = ByteBuffer.allocateDirect(interleaved.size * 2).order(ByteOrder.nativeOrder())
        interleaved.forEach { buf.putShort(it) }
        buf.flip()
        p.queueInput(buf)
        val o = p.output
        return ShortArray(o.remaining() / 2) { o.short }
    }

    @Test
    fun processorSendsOnlyItsChannelToBothSpeakers() {
        // Two frames: (L, R) = (1000, -3000), (2000, 500).
        val pcm = shortArrayOf(1000, -3000, 2000, 500)
        assertContentEquals(shortArrayOf(1000, 1000, 2000, 2000), process("left", pcm))
        assertContentEquals(shortArrayOf(-3000, -3000, 500, 500), process("right", pcm))
        assertContentEquals(shortArrayOf(-1000, -1000, 1250, 1250), process("mono", pcm))
        // Stereo leaves the audio untouched (processor inactive).
        assertNull(process("stereo", pcm))
    }

    @Test
    fun leftOnlySoundIsSilentOnTheRightPhone() {
        // The speaker test's left beeps: nothing in the right channel.
        val pcm = shortArrayOf(12000, 0, -8000, 0)
        assertContentEquals(shortArrayOf(0, 0, 0, 0), process("right", pcm))
        assertFalse(process("left", pcm)!!.all { it.toInt() == 0 })
    }
}
