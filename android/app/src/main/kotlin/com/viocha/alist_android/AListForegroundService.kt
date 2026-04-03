package com.viocha.alist_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class AListForegroundService : Service() {
    private var cpuWakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createNotificationChannel()

        when (intent?.action) {
            ACTION_STOP -> {
                AListRuntime.stop(applicationContext)
                stopServiceNotification()
                return START_NOT_STICKY
            }

            ACTION_RESTORE_NOTIFICATION -> {
                val status = AListRuntime.getStatus(applicationContext)
                val running = status["running"] == true
                val port = (status["port"] as? Number)?.toInt() ?: 5244
                if (running) {
                    acquireRuntimeLocks()
                    startForeground(
                        NOTIFICATION_ID,
                        buildNotification("服务运行中，端口 $port", port),
                    )
                    return START_STICKY
                }
                stopServiceNotification()
                return START_NOT_STICKY
            }

            ACTION_UPDATE_NOTIFICATION -> {
                val port = intent.getIntExtra(EXTRA_PORT, 5244)
                val message =
                    intent.getStringExtra(EXTRA_MESSAGE) ?: "服务运行中，端口 $port"
                notificationManager().notify(
                    NOTIFICATION_ID,
                    buildNotification(message, port),
                )
                return START_STICKY
            }

            ACTION_START -> {
                val port = intent.getIntExtra(EXTRA_PORT, 5244)
                val password = intent.getStringExtra(EXTRA_PASSWORD) ?: ""

                acquireRuntimeLocks()

                val startResult = AListRuntime.start(applicationContext, port, password) {
                    stopServiceNotification()
                }

                if (!startResult.success) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                return START_STICKY
            }

            else -> {
                return START_NOT_STICKY
            }
        }
    }

    override fun onDestroy() {
        if (AListRuntime.getStatus(applicationContext)["running"] == true) {
            AListRuntime.stop(applicationContext)
        }
        releaseRuntimeLocks()
        super.onDestroy()
    }

    private fun buildNotification(content: String, port: Int): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openAppPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val stopIntent = Intent(this, AListForegroundService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val restoreIntent = Intent(this, AListForegroundService::class.java).apply {
            action = ACTION_RESTORE_NOTIFICATION
        }
        val restorePendingIntent = PendingIntent.getService(
            this,
            2,
            restoreIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle("AList")
            .setContentText(content)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openAppPendingIntent)
            .setDeleteIntent(restorePendingIntent)
            .addAction(android.R.drawable.ic_media_pause, "停止", stopPendingIntent)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            CHANNEL_ID,
            "AList Service",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps the AList service running in foreground."
        }
        notificationManager().createNotificationChannel(channel)
    }

    private fun notificationManager(): NotificationManager {
        return getSystemService(NotificationManager::class.java)
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun stopServiceNotification() {
        releaseRuntimeLocks()
        stopForegroundCompat()
        notificationManager().cancel(NOTIFICATION_ID)
        stopSelf()
    }

    private fun acquireRuntimeLocks() {
        if (cpuWakeLock?.isHeld != true) {
            val powerManager = getSystemService(PowerManager::class.java)
            cpuWakeLock = powerManager
                ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:AListCpu")
                ?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
    }

    private fun releaseRuntimeLocks() {
        cpuWakeLock?.run {
            if (isHeld) {
                release()
            }
        }
        cpuWakeLock = null
    }

    companion object {
        const val ACTION_START = "com.viocha.alist_android.action.START"
        const val ACTION_STOP = "com.viocha.alist_android.action.STOP"
        const val ACTION_RESTORE_NOTIFICATION = "com.viocha.alist_android.action.RESTORE_NOTIFICATION"
        const val ACTION_UPDATE_NOTIFICATION = "com.viocha.alist_android.action.UPDATE_NOTIFICATION"
        const val EXTRA_PORT = "extra_port"
        const val EXTRA_PASSWORD = "extra_password"
        const val EXTRA_MESSAGE = "extra_message"

        private const val CHANNEL_ID = "alist_service_channel"
        private const val NOTIFICATION_ID = 4041
    }
}
