package dev.syncsphere.syncsphere_audio

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
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
import io.flutter.plugin.common.PluginRegistry

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
 *   setChannelRole {role} ("stereo" | "left" | "right" | "mono" | "center" | "surroundLeft" | "surroundRight")
 *   requestPermission {name} ("microphone" | "notifications" | "audio") → Boolean
 *   recordMic {startAtNanos, durationMs, sampleRate} → {path, sampleRate, firstSampleNanos, timestampSource}
 *   startService {title, text, playing}, updateService {…}, stopService
 *   exactCopy {uri, out} → {path, sampleRate, channels, durationUs, decoder} (decode to PCM WAV)
 *   extractArtwork {uri, out} → Boolean (embedded cover → JPEG at out)
 *   moveToBack → Boolean (app to background, keeps running)
 *   queryAudio → [{uri, title, artist, album, albumId, durationMs, size, mime, name}] (needs "audio" permission)
 *   copyContent {uri, out} → Long (bytes copied from a content:// URI)
 *   takeSharedAudio → [{uri, name, size, mime}] (audio shared to the app; cleared once taken)
 * Event channel `dev.syncsphere/audio_events`: {kind, segment, atNanos, message};
 * notification buttons arrive as {kind: "command", message: play|pause|next|previous}; audio shared
 * while the app runs as {kind: "shared"}.
 */
class SyncsphereAudioPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    companion object {
        private const val PERMISSION_REQUEST = 4781
        private const val CONSUMED = "dev.syncsphere.shareConsumed"
    }

    private lateinit var channel: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var engine: SyncAudioEngine? = null
    private var locks: NetworkLocks? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermission: Result? = null
    private val sharedUris = LinkedHashSet<String>()
    private val newIntentListener = PluginRegistry.NewIntentListener { intent ->
        if (takeShare(intent)) {
            main.post { sink?.success(mapOf("kind" to "shared", "segment" to -1, "atNanos" to System.nanoTime(), "message" to null)) }
        }
        false
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dev.syncsphere/audio")
        channel.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "dev.syncsphere/audio_events")
        events.setStreamHandler(this)
        PlaybackService.commandListener = { cmd ->
            main.post { sink?.success(mapOf("kind" to "command", "segment" to -1, "atNanos" to System.nanoTime(), "message" to cmd)) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        engine?.dispose()
        engine = null
        locks?.release()
        locks = null
        PlaybackService.commandListener = null
        PlaybackService.stop(context)
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
                "extractArtwork" -> {
                    val uri = call.argument<String>("uri") ?: throw IllegalArgumentException("uri missing")
                    val out = call.argument<String>("out") ?: throw IllegalArgumentException("out missing")
                    Thread {
                        try {
                            val ok = TrackProbe.artwork(context, uri, java.io.File(out))
                            main.post { result.success(ok) }
                        } catch (e: Exception) {
                            main.post { result.error("artwork_failed", e.message, null) }
                        }
                    }.start()
                }
                "moveToBack" -> result.success(activity?.moveTaskToBack(true) ?: false)
                "queryAudio" -> Thread {
                    try {
                        val list = DeviceMedia.queryAudio(context)
                        main.post { result.success(list) }
                    } catch (e: SecurityException) {
                        main.post { result.error("permission_denied", "music access not granted", null) }
                    } catch (e: Exception) {
                        main.post { result.error("query_failed", e.message, null) }
                    }
                }.start()
                "copyContent" -> {
                    val uri = call.argument<String>("uri") ?: throw IllegalArgumentException("uri missing")
                    val out = call.argument<String>("out") ?: throw IllegalArgumentException("out missing")
                    Thread {
                        try {
                            val n = DeviceMedia.copyContent(context, uri, java.io.File(out))
                            main.post { result.success(n) }
                        } catch (e: Exception) {
                            main.post { result.error("copy_failed", e.message ?: e.javaClass.simpleName, null) }
                        }
                    }.start()
                }
                "takeSharedAudio" -> {
                    val uris = sharedUris.toList()
                    sharedUris.clear()
                    result.success(uris.map { DeviceMedia.describe(context, it) })
                }
                "keepScreenOn" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    activity?.window?.let { w ->
                        if (on) w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else w.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(activity != null)
                }
                "setChannelRole" -> {
                    val role = call.argument<String>("role") ?: throw IllegalArgumentException("role missing")
                    if (role !in setOf("stereo", "left", "right", "mono", "center", "surroundLeft", "surroundRight")) {
                        throw IllegalArgumentException("unknown role $role")
                    }
                    engine().setChannelRole(role)
                    result.success(null)
                }
                "requestPermission" -> requestPermission(call.argument<String>("name") ?: "", result)
                "recordMic" -> {
                    val granted =
                        context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
                    if (!granted) {
                        result.error("permission_denied", "microphone permission not granted", null)
                        return
                    }
                    MicRecorder(context).record(
                        call.long("startAtNanos"),
                        call.long("durationMs").coerceIn(100, 120_000),
                        call.argument<Number>("sampleRate")?.toInt() ?: 48000,
                    ) { info, err ->
                        main.post { if (err == null) result.success(info) else result.error("record_failed", err, null) }
                    }
                }
                "startService" -> {
                    PlaybackService.start(context, call.str("title"), call.str("text"), call.argument<Boolean>("playing") ?: false)
                    result.success(null)
                }
                "updateService" -> {
                    val svc = PlaybackService.instance
                    svc?.update(call.str("title"), call.str("text"), call.argument<Boolean>("playing") ?: false)
                    result.success(svc != null)
                }
                "exactCopy" -> {
                    val uri = call.argument<String>("uri") ?: throw IllegalArgumentException("uri missing")
                    val out = call.argument<String>("out") ?: throw IllegalArgumentException("out missing")
                    Thread {
                        try {
                            val info = TrackTranscoder.toWav(context, uri, java.io.File(out))
                            main.post { result.success(info) }
                        } catch (e: Exception) {
                            main.post { result.error("transcode_failed", e.message ?: e.javaClass.simpleName, null) }
                        }
                    }.apply { name = "SyncSphereTranscode" }.start()
                }
                "stopService" -> {
                    PlaybackService.stop(context)
                    result.success(null)
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

    private fun MethodCall.str(name: String): String = argument<String>(name) ?: ""

    private fun requestPermission(name: String, result: Result) {
        val permission = when (name) {
            "microphone" -> Manifest.permission.RECORD_AUDIO
            "notifications" -> if (Build.VERSION.SDK_INT >= 33) Manifest.permission.POST_NOTIFICATIONS else null
            "audio" -> if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO else Manifest.permission.READ_EXTERNAL_STORAGE
            else -> throw IllegalArgumentException("unknown permission $name")
        }
        if (permission == null ||
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null || pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        act.requestPermissions(arrayOf(permission), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val r = pendingPermission ?: return true
        pendingPermission = null
        r.success(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
        return true
    }

    // EventChannel.StreamHandler
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ActivityAware
    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding)

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attach(binding)

    override fun onDetachedFromActivity() = detach()

    private fun attach(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addOnNewIntentListener(newIntentListener)
        takeShare(binding.activity.intent)
    }

    /** Remembers audio shared by [intent] (once per intent, also across recreation). */
    private fun takeShare(intent: Intent?): Boolean {
        if (intent == null || intent.getBooleanExtra(CONSUMED, false)) return false
        val uris = DeviceMedia.sharedUris(intent)
        if (uris.isEmpty()) return false
        intent.putExtra(CONSUMED, true)
        sharedUris.addAll(uris)
        return true
    }

    private fun detach() {
        activityBinding?.removeOnNewIntentListener(newIntentListener)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        pendingPermission?.success(false)
        pendingPermission = null
    }
}
