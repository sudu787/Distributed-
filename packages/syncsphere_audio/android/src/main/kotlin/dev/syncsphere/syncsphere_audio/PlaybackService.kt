package dev.syncsphere.syncsphere_audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder

/**
 * Foreground service that keeps SyncSphere (Dart isolate, network sockets
 * and the audio thread) alive while the screen is off or another app is in
 * front, and shows a notification with room controls.
 *
 * Notification buttons send *room* commands (play/pause/next/previous go
 * through the coordinator like any other control), not local player
 * actions, so pressing pause pauses the whole room.
 */
class PlaybackService : Service() {
    companion object {
        const val CHANNEL_ID = "syncsphere_playback"
        const val NOTIFICATION_ID = 4780
        const val ACTION_START = "dev.syncsphere.START"
        const val ACTION_STOP = "dev.syncsphere.STOP"
        const val ACTION_COMMAND = "dev.syncsphere.COMMAND"

        @Volatile var instance: PlaybackService? = null

        /** Receives notification button presses (set by the plugin). */
        @Volatile var commandListener: ((String) -> Unit)? = null

        fun start(context: Context, title: String, text: String, playing: Boolean) {
            val i = Intent(context, PlaybackService::class.java).setAction(ACTION_START)
                .putExtra("title", title).putExtra("text", text).putExtra("playing", playing)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
        }

        fun stop(context: Context) {
            instance?.let {
                it.stopForegroundCompat()
                it.stopSelf()
            } ?: context.stopService(Intent(context, PlaybackService::class.java))
        }
    }

    private var title = "SyncSphere"
    private var text = ""
    private var playing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        ensureChannel()
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                title = intent.getStringExtra("title") ?: title
                text = intent.getStringExtra("text") ?: text
                playing = intent.getBooleanExtra("playing", false)
                goForeground()
            }
            ACTION_COMMAND -> intent.getStringExtra("cmd")?.let { cmd -> commandListener?.invoke(cmd) }
            ACTION_STOP -> {
                stopForegroundCompat()
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    /** Updates the notification in place (called by the plugin). */
    fun update(title: String, text: String, playing: Boolean) {
        this.title = title
        this.text = text
        this.playing = playing
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, build())
    }

    private fun goForeground() {
        val n = build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    fun stopForegroundCompat() = stopForeground(STOP_FOREGROUND_REMOVE)

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val ch = NotificationChannel(CHANNEL_ID, "Room playback", NotificationManager.IMPORTANCE_LOW)
            ch.description = "Shows the room you are in and its playback controls"
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
    }

    private fun commandIntent(cmd: String, code: Int): PendingIntent =
        PendingIntent.getService(
            this,
            code,
            Intent(this, PlaybackService::class.java).setAction(ACTION_COMMAND).putExtra("cmd", cmd),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun action(icon: Int, label: String, cmd: String, code: Int): Notification.Action =
        Notification.Action.Builder(Icon.createWithResource(this, icon), label, commandIntent(cmd, code)).build()

    @Suppress("DEPRECATION")
    private fun build(): Notification {
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) {
            b.setContentIntent(PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE))
        }
        return b.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(action(android.R.drawable.ic_media_previous, "Previous", "previous", 1))
            .addAction(
                if (playing) action(android.R.drawable.ic_media_pause, "Pause", "pause", 2)
                else action(android.R.drawable.ic_media_play, "Play", "play", 3),
            )
            .addAction(action(android.R.drawable.ic_media_next, "Next", "next", 4))
            .setStyle(Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2))
            .build()
    }
}
