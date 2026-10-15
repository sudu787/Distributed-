package dev.syncsphere.syncsphere_audio

import kotlin.test.Test
import kotlin.test.assertContentEquals

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
}
