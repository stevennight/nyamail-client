package com.nyatori.nyamail

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground service that keeps the NyaMail process (and with it the cached
 * Flutter engine, its IMAP IDLE connections and polling timers) alive while
 * the app is in the background. It does no mail work itself: credentials only
 * ever live decrypted inside the unlocked Dart vault.
 */
class MailSyncService : Service() {
    companion object {
        private const val CHANNEL_ID = "nyamail_background_sync"
        private const val NOTIFICATION_ID = 7301
        private const val WAKE_LOCK_TAG = "NyaMail:mailSync"

        private var wakeLock: PowerManager.WakeLock? = null

        fun start(context: Context) {
            val intent = Intent(context, MailSyncService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MailSyncService::class.java))
            releaseWakeLock()
        }

        /**
         * Keeps the CPU awake for a bounded time so a refresh triggered by an
         * IDLE push can finish before the device dozes off again.
         */
        @Synchronized
        fun acquireWakeLock(context: Context, timeoutMs: Long) {
            val lock = wakeLock ?: (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
                .also {
                    it.setReferenceCounted(false)
                    wakeLock = it
                }
            lock.acquire(timeoutMs)
        }

        @Synchronized
        fun releaseWakeLock() {
            val lock = wakeLock ?: return
            if (lock.isHeld) lock.release()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_mail)
            .setContentTitle("NyaMail")
            .setContentText("Checking for new mail in the background")
            .setOngoing(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(contentIntent)
            .build()
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
        // Without the unlocked vault in the Dart isolate a restarted service
        // could not do anything useful, so do not ask to be restarted.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Background sync",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = "Shown while NyaMail keeps checking for new mail in the background."
                setShowBadge(false)
            }
        )
    }
}
