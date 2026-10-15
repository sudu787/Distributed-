package dev.syncsphere.syncsphere_audio

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build

/**
 * Wi-Fi locks held while the device is in a room.
 *
 * * Low-latency WifiLock (API 29+, high-performance before that) keeps the
 *   radio out of aggressive power save. Power save buffers downlink frames
 *   until the next beacon/DTIM, which shows up as 100+ ms latency spikes and
 *   makes clock-offset samples asymmetric. It only takes effect while the app
 *   is in the foreground with the screen on.
 * * MulticastLock lets broadcast/multicast discovery packets through; many
 *   devices filter them otherwise.
 */
class NetworkLocks(context: Context) {
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager?
    private var wifiLock: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    fun acquire(): Map<String, Any?> {
        val w = wifi ?: return mapOf("wifi" to false, "multicast" to false)
        if (wifiLock == null) {
            wifiLock = w.createWifiLock(lockMode(), "SyncSphere:sync").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (multicastLock == null) {
            multicastLock = w.createMulticastLock("SyncSphere:discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        return mapOf(
            "wifi" to (wifiLock?.isHeld == true),
            "multicast" to (multicastLock?.isHeld == true),
            "lowLatencyMode" to (Build.VERSION.SDK_INT >= 29),
        )
    }

    fun release() {
        wifiLock?.let { if (it.isHeld) it.release() }
        multicastLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        multicastLock = null
    }

    @Suppress("DEPRECATION")
    private fun lockMode(): Int =
        if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        else WifiManager.WIFI_MODE_FULL_HIGH_PERF
}
