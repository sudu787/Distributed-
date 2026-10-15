package dev.syncsphere.syncsphere_audio

import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

/** Static facts about the device's audio path, for diagnostics and hints. */
object DeviceAudioInfo {
    fun describe(context: Context): Map<String, Any?> {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val pm = context.packageManager
        val sampleRate = am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull()
        val framesPerBuffer = am.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull()
        val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val bluetooth = outputs.any {
            it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || it.type == AudioDeviceInfo.TYPE_BLE_SPEAKER ||
                it.type == AudioDeviceInfo.TYPE_BLE_HEADSET
        }
        val wired = outputs.any {
            it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES || it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                it.type == AudioDeviceInfo.TYPE_USB_HEADSET
        }
        // Heuristic prior for the play-call → audible delay, used only until
        // the engine has measured this device. Two mixer buffers plus a
        // typical ExoPlayer/AudioTrack start-up allowance; it ignores
        // Bluetooth, which needs acoustic calibration.
        val hintUs: Long? = if (sampleRate != null && framesPerBuffer != null && sampleRate > 0) {
            2L * framesPerBuffer * 1_000_000L / sampleRate + 30_000L
        } else null
        return mapOf(
            "backend" to "media3-exoplayer",
            "rateControl" to true,
            "minRate" to 0.5,
            "maxRate" to 2.0,
            "outputLatencyHintUs" to hintUs,
            "sampleRate" to sampleRate,
            "framesPerBuffer" to framesPerBuffer,
            "lowLatencyFeature" to pm.hasSystemFeature(PackageManager.FEATURE_AUDIO_LOW_LATENCY),
            "proAudioFeature" to pm.hasSystemFeature(PackageManager.FEATURE_AUDIO_PRO),
            "bluetoothOutputPresent" to bluetooth,
            "wiredOutputPresent" to wired,
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }
}
