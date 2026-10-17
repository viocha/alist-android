package com.viocha.alist_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.Context
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import java.net.Inet4Address
import java.net.NetworkInterface

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
                    updateForegroundNotification(port, "服务运行中")
                    return START_STICKY
                }
                stopServiceNotification()
                return START_NOT_STICKY
            }

            ACTION_UPDATE_NOTIFICATION -> {
                if (AListRuntime.getStatus(applicationContext)["running"] != true) {
                    stopServiceNotification()
                    return START_NOT_STICKY
                }
                val port = intent.getIntExtra(EXTRA_PORT, 5244)
                val message = intent.getStringExtra(EXTRA_MESSAGE) ?: "服务运行中"
                updateForegroundNotification(port, message)
                return START_STICKY
            }

            ACTION_START -> {
                val port = intent.getIntExtra(EXTRA_PORT, 5244)

                acquireRuntimeLocks()
                updateForegroundNotification(port, "正在启动服务…")

                val startResult = AListRuntime.start(applicationContext, port) {
                    stopServiceNotification()
                }

                if (!startResult.success) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                updateForegroundNotification(port, "服务运行中")
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
        val accessUrls = resolveLocalAccessUrls(port)
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

        val lanAccessUrls = accessUrls.filterNot { url -> url.startsWith("http://localhost:") }
        val collapsedText = lanAccessUrls.firstOrNull() ?: "端口 $port"
        val expandedText =
            if (lanAccessUrls.isEmpty()) {
                "局域网访问地址暂不可用"
            } else {
                lanAccessUrls.joinToString(separator = "\n")
            }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle("AList")
            .setContentText(collapsedText)
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(expandedText)
                    .setSummaryText("AList 服务"),
            )
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openAppPendingIntent)
            .setDeleteIntent(restorePendingIntent)
            .addAction(android.R.drawable.ic_media_pause, "停止", stopPendingIntent)
            .build()
    }

    private fun updateForegroundNotification(port: Int, content: String) {
        startForeground(
            NOTIFICATION_ID,
            buildNotification(content, port),
        )
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

    private fun resolveLocalAccessUrls(port: Int): List<String> {
        val privateHosts = linkedSetOf<String>()
        val fallbackHosts = linkedSetOf<String>()

        NetworkInterface.getNetworkInterfaces()?.toList()?.forEach { networkInterface ->
            if (!networkInterface.isUp || networkInterface.isLoopback) {
                return@forEach
            }

            networkInterface.inetAddresses.toList().forEach { address ->
                val inet4Address = address as? Inet4Address ?: return@forEach
                val host = inet4Address.hostAddress ?: return@forEach
                if (host.startsWith("127.") || host.startsWith("169.254.")) {
                    return@forEach
                }

                if (isPrivateIpv4(host)) {
                    privateHosts.add(host)
                } else {
                    fallbackHosts.add(host)
                }
            }
        }

        val selectedHosts = if (privateHosts.isNotEmpty()) privateHosts else fallbackHosts
        return buildList {
            add("http://localhost:$port")
            addAll(
                selectedHosts
                    .sortedWith(::compareIpv4Hosts)
                    .map { host -> "http://$host:$port" },
            )
        }
    }

    private fun isPrivateIpv4(host: String): Boolean {
        val octets = host.split(".").mapNotNull { part -> part.toIntOrNull() }
        if (octets.size != 4) {
            return false
        }

        val a = octets[0]
        val b = octets[1]
        return a == 10 || (a == 172 && b in 16..31) || (a == 192 && b == 168)
    }

    private fun compareIpv4Hosts(left: String, right: String): Int {
        val rankDiff = ipv4SortRank(left) - ipv4SortRank(right)
        if (rankDiff != 0) {
            return rankDiff
        }

        val leftOctets = left.split(".").map { it.toInt() }
        val rightOctets = right.split(".").map { it.toInt() }
        for (index in 0..3) {
            val diff = leftOctets[index] - rightOctets[index]
            if (diff != 0) {
                return diff
            }
        }
        return 0
    }

    private fun ipv4SortRank(host: String): Int {
        return when {
            host.startsWith("192.168.") -> 0
            host.startsWith("172.") -> 1
            host.startsWith("10.") -> 2
            else -> 3
        }
    }

    companion object {
        // 前台恢复只修复通知，不启动 AList 进程；服务端再次核实运行状态。
        fun restoreNotificationIfMissing(context: Context) {
            if (AListRuntime.getStatus(context)["running"] != true) return
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.activeNotifications.any { it.id == NOTIFICATION_ID && it.tag == null }) return
            context.startService(Intent(context, AListForegroundService::class.java).apply {
                action = ACTION_RESTORE_NOTIFICATION
            })
        }

        const val ACTION_START = "com.viocha.alist_android.action.START"
        const val ACTION_STOP = "com.viocha.alist_android.action.STOP"
        const val ACTION_RESTORE_NOTIFICATION = "com.viocha.alist_android.action.RESTORE_NOTIFICATION"
        const val ACTION_UPDATE_NOTIFICATION = "com.viocha.alist_android.action.UPDATE_NOTIFICATION"
        const val EXTRA_PORT = "extra_port"
        const val EXTRA_MESSAGE = "extra_message"

        private const val CHANNEL_ID = "alist_service_channel"
        private const val NOTIFICATION_ID = 4041
    }
}
