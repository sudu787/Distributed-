package dev.syncsphere.syncsphere_audio

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Platform-channel surface of the SyncSphere audio backend.
 *
 * Method channel `dev.syncsphere/audio` (all times are System.nanoTime()):
 *   nowNanos → Long
 *   init → Map (device audio info / capabilities)
 *   prepare {segment, uri, positionUs} → null | error
 *   startAt {segment, atNanos}
 *   pauseAt {segment, atNanos, seekToUs?}
 *   setRate {rate}, setVolume {volume}, stop
 *   sample → Map | null
 *   acquireNetworkLocks → Map, releaseNetworkLocks
 *   keepScreenOn {on}
 *   probe {uri} → {durationMs, title, artist, album, mimeType}
 * Event channel `dev.syncsphere/audio_events`: {kind, segment, atNanos, message}
 */
class SyncsphereAudioPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var engine: SyncAudioEngine? = null
    private var locks: NetworkLocks? = null
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dev.syncsphere/audio")
        channel.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "dev.syncsphere/audio_events")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        engine?.dispose()
        engine = null
        locks?.release()
        locks = null
    }

    private fun engine(): SyncAudioEngine =
        engine ?: SyncAudioEngine(context) { ev -> main.post { sink?.success(ev) } }.also { engine = it }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "nowNanos" -> result.success(System.nanoTime())
                "init" -> {
                    engine()
                    result.success(DeviceAudioInfo.describe(context))
                }
                "prepare" -> {
                    val segment = call.int("segment")
                    val uri = call.argument<String>("uri") ?: throw IllegalArgumentException("uri missing")
                    engine().prepare(segment, uri, call.long("positionUs")) { err ->
                        if (err == null) result.success(null) else result.error("prepare_failed", err, null)
                    }
                }
                "startAt" -> {
                    engine().startAt(call.int("segment"), call.long("atNanos"))
                    result.success(null)
                }
                "pauseAt" -> {
                    val seek = call.argument<Number>("seekToUs")?.toLong()
                    engine().pauseAt(call.int("segment"), call.long("atNanos"), seek)
                    result.success(null)
                }
                "setRate" -> {
                    engine().setRate(call.double("rate").toFloat())
                    result.success(null)
                }
                "setVolume" -> {
                    engine().setVolume(call.double("volume").toFloat().coerceIn(0f, 1f))
                    result.success(null)
                }
                "stop" -> {
                    engine?.stop()
                    result.success(null)
                }
                "sample" -> engine().sample { m -> result.success(m) }
                "acquireNetworkLocks" -> {
                    val l = locks ?: NetworkLocks(context).also { locks = it }
                    result.success(l.acquire())
                }
                "releaseNetworkLocks" -> {
                    locks?.release()
                    result.success(null)
                }
                "probe" -> {
                    val uri = call.argument<String>("uri") ?: throw IllegalArgumentException("uri missing")
                    // MediaMetadataRetriever can take a while on large files.
                    Thread {
                        try {
                            val info = TrackProbe.probe(context, uri)
                            main.post { result.success(info) }
                        } catch (e: Exception) {
                            main.post { result.error("probe_failed", e.message, null) }
                        }
                    }.start()
                }
                "keepScreenOn" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    activity?.window?.let { w ->
                        if (on) w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else w.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(activity != null)
                }
                else -> result.notImplemented()
            }
        } catch (e: IllegalArgumentException) {
            result.error("bad_args", e.message, null)
        } catch (e: Exception) {
            result.error("native_error", e.message, null)
        }
    }

    private fun MethodCall.int(name: String): Int =
        argument<Number>(name)?.toInt() ?: throw IllegalArgumentException("$name missing")

    private fun MethodCall.long(name: String): Long =
        argument<Number>(name)?.toLong() ?: throw IllegalArgumentException("$name missing")

    private fun MethodCall.double(name: String): Double =
        argument<Number>(name)?.toDouble() ?: throw IllegalArgumentException("$name missing")

    // EventChannel.StreamHandler
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ActivityAware
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }
}
