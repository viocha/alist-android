package com.viocha.alist_android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Environment
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private var pendingStoragePermissionResult: MethodChannel.Result? = null
    private var awaitingManageStorageResult = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var runtimeEventSink: EventChannel.EventSink? = null
    private val runtimeObserver =
        RuntimeEventObserver { event ->
            mainHandler.post {
                runtimeEventSink?.success(event)
            }
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).setMethodCallHandler(::handleMethodCall)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENTS_CHANNEL_NAME,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    runtimeEventSink = events
                    AListRuntime.addObserver(runtimeObserver)
                    events.success(
                        mapOf(
                            "type" to "status",
                            "status" to AListRuntime.getStatus(applicationContext),
                        ),
                    )
                }

                override fun onCancel(arguments: Any?) {
                    runtimeEventSink = null
                    AListRuntime.removeObserver(runtimeObserver)
                }
            },
        )
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getPaths" -> result.success(AListRuntime.getPaths(applicationContext))
            "getStatus" -> result.success(AListRuntime.getStatus(applicationContext))
            "readLogs" -> {
                val maxBytes = call.argument<Int>("maxBytes") ?: DEFAULT_LOG_BYTES
                result.success(AListRuntime.readLogTail(applicationContext, maxBytes))
            }
            "ensureBinaryExecutable" -> {
                val binaryPath = call.argument<String>("binaryPath")
                if (binaryPath.isNullOrBlank()) {
                    result.error("bad_args", "binaryPath is required", null)
                    return
                }
                val executable = AListRuntime.ensureBinaryExecutable(binaryPath)
                result.success(executable)
            }
            "initializeDataDirectory" -> {
                val commandResult = AListRuntime.initializeDataDirectory(applicationContext)
                result.success(commandResult.toMap())
            }
            "applyAdminPassword" -> {
                val password = call.argument<String>("password")
                if (password.isNullOrBlank()) {
                    result.error("bad_args", "password is required", null)
                    return
                }
                val commandResult = AListRuntime.applyAdminPassword(applicationContext, password)
                result.success(commandResult.toMap())
            }
            "getStoragePermissionStatus" -> result.success(getStoragePermissionStatus())
            "ensureStoragePermission" -> ensureStoragePermission(result)
            "openStoragePermissionSettings" -> openStoragePermissionSettings(result)
            "requestNotificationPermission" -> requestNotificationPermission(result)
            "openBatterySettings" -> openBatterySettings(result)
            "openInBrowser" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("bad_args", "url is required", null)
                    return
                }
                openInBrowser(url, result)
            }
            "startService" -> {
                val port = call.argument<Int>("port") ?: 5244
                val intent = Intent(applicationContext, AListForegroundService::class.java).apply {
                    action = AListForegroundService.ACTION_START
                    putExtra(AListForegroundService.EXTRA_PORT, port)
                }
                applicationContext.startService(intent)
                result.success(
                    mapOf(
                        "success" to true,
                        "message" to "Foreground service start requested.",
                    ),
                )
            }
            "updateServiceNotification" -> {
                val port = call.argument<Int>("port") ?: 5244
                val message = call.argument<String>("message") ?: "服务运行中，端口 $port"
                val intent = Intent(applicationContext, AListForegroundService::class.java).apply {
                    action = AListForegroundService.ACTION_UPDATE_NOTIFICATION
                    putExtra(AListForegroundService.EXTRA_PORT, port)
                    putExtra(AListForegroundService.EXTRA_MESSAGE, message)
                }
                applicationContext.startService(intent)
                result.success(
                    mapOf(
                        "success" to true,
                        "message" to "Foreground notification update requested.",
                        "shouldNotify" to false,
                    ),
                )
            }
            "stopService" -> {
                val intent = Intent(applicationContext, AListForegroundService::class.java).apply {
                    action = AListForegroundService.ACTION_STOP
                }
                applicationContext.startService(intent)
                result.success(
                    mapOf(
                        "success" to true,
                        "message" to "Foreground service stop requested.",
                    ),
                )
            }
            else -> result.notImplemented()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        when (requestCode) {
            NOTIFICATION_PERMISSION_REQUEST_CODE -> {
                val granted =
                    grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
                pendingNotificationPermissionResult?.success(
                    mapOf(
                        "success" to granted,
                        "message" to if (granted) {
                            "Notification permission granted."
                        } else {
                            "需要通知权限才能显示常驻服务通知。"
                        },
                    ),
                )
                pendingNotificationPermissionResult = null
            }
            STORAGE_PERMISSION_REQUEST_CODE -> {
                val granted =
                    grantResults.isNotEmpty() &&
                        grantResults.all { grantResult ->
                            grantResult == PackageManager.PERMISSION_GRANTED
                        }
                pendingStoragePermissionResult?.success(
                    mapOf(
                        "success" to granted,
                        "message" to if (granted) {
                            "已授予文件访问权限。"
                        } else {
                            "需要文件访问权限才能让 AList 读取本地存储内容。"
                        },
                    ),
                )
                pendingStoragePermissionResult = null
            }
        }
    }

    override fun onResume() {
        super.onResume()
        AListForegroundService.restoreNotificationIfMissing(applicationContext)

        if (!awaitingManageStorageResult) {
            return
        }

        awaitingManageStorageResult = false
        val result = pendingStoragePermissionResult ?: return
        pendingStoragePermissionResult = null
        result.success(getStoragePermissionStatus())
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(
                mapOf(
                    "success" to true,
                    "message" to "Notification permission not required.",
                ),
            )
            return
        }

        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(
                mapOf(
                    "success" to true,
                    "message" to "Notification permission granted.",
                ),
            )
            return
        }

        if (pendingNotificationPermissionResult != null) {
            result.success(
                mapOf(
                    "success" to false,
                    "message" to "A permission request is already in progress.",
                ),
            )
            return
        }

        pendingNotificationPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
    }

    private fun getStoragePermissionStatus(): Map<String, Any> {
        val granted = hasStoragePermission()
        return mapOf(
            "success" to granted,
            "message" to if (granted) {
                "已授予文件访问权限。"
            } else {
                "需要文件访问权限才能让 AList 访问本地存储。"
            },
            "shouldNotify" to false,
        )
    }

    private fun ensureStoragePermission(result: MethodChannel.Result) {
        if (hasStoragePermission()) {
            result.success(
                mapOf(
                    "success" to true,
                    "message" to "已授予文件访问权限。",
                    "shouldNotify" to false,
                ),
            )
            return
        }

        if (pendingStoragePermissionResult != null) {
            result.success(
                mapOf(
                    "success" to false,
                    "message" to "A permission request is already in progress.",
                    "shouldNotify" to false,
                ),
            )
            return
        }

        pendingStoragePermissionResult = result

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            awaitingManageStorageResult = true
            startActivity(buildStoragePermissionIntent())
            return
        }

        val permissions = buildList {
            add(Manifest.permission.READ_EXTERNAL_STORAGE)
            add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }.toTypedArray()

        ActivityCompat.requestPermissions(
            this,
            permissions,
            STORAGE_PERMISSION_REQUEST_CODE,
        )
    }

    private fun openStoragePermissionSettings(result: MethodChannel.Result) {
        startActivity(buildStoragePermissionIntent())
        result.success(
            mapOf(
                "success" to true,
                "message" to "已打开文件权限设置。",
                "shouldNotify" to false,
            ),
        )
    }

    private fun hasStoragePermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager()
        }

        val readGranted =
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED
        val writeGranted =
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED
        return readGranted && writeGranted
    }

    private fun buildStoragePermissionIntent(): Intent {
        val packageUri = Uri.parse("package:$packageName")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                data = packageUri
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val fallbackIntent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            return when {
                intent.resolveActivity(packageManager) != null -> intent
                fallbackIntent.resolveActivity(packageManager) != null -> fallbackIntent
                else -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = packageUri
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
        }

        return Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = packageUri
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }

    private fun openBatterySettings(result: MethodChannel.Result) {
        val packageName = applicationContext.packageName
        val intents = listOf(
            Intent().apply {
                setClassName(
                    "com.miui.securitycenter",
                    "com.miui.powercenter.legacypowerrank.PowerDetailActivity",
                )
                putExtra("package_name", packageName)
                putExtra("packageName", packageName)
                putExtra("android.provider.extra.APP_PACKAGE", packageName)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
            Intent("android.settings.APP_BATTERY_SETTINGS").apply {
                putExtra("android.provider.extra.APP_PACKAGE", packageName)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )

        val launched = intents.firstOrNull { intent ->
            intent.resolveActivity(packageManager) != null
        }

        if (launched == null) {
            result.success(
                mapOf(
                    "success" to false,
                    "message" to "无法打开电池策略设置。",
                    "shouldNotify" to false,
                ),
            )
            return
        }

        startActivity(launched)
        result.success(
            mapOf(
                "success" to true,
                "message" to "已打开电池策略设置。",
                "shouldNotify" to false,
            ),
        )
    }

    private fun openInBrowser(url: String, result: MethodChannel.Result) {
        val browserIntent = Intent(Intent.ACTION_VIEW).apply {
            data = Uri.parse(url)
            addCategory(Intent.CATEGORY_BROWSABLE)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val resolvedActivity = browserIntent.resolveActivity(packageManager)
        if (resolvedActivity == null) {
            result.success(
                mapOf(
                    "success" to false,
                    "message" to "未找到可用的浏览器来打开 $url",
                    "shouldNotify" to true,
                ),
            )
            return
        }

        try {
            applicationContext.startActivity(browserIntent)
            result.success(
                mapOf(
                    "success" to true,
                    "message" to "已在浏览器中打开 $url",
                    "shouldNotify" to false,
                ),
            )
        } catch (_: Exception) {
            result.success(
                mapOf(
                    "success" to false,
                    "message" to "无法在浏览器中打开 $url",
                    "shouldNotify" to true,
                ),
            )
        }
    }

    companion object {
        private const val CHANNEL_NAME = "com.viocha.alist_android/runtime"
        private const val EVENTS_CHANNEL_NAME = "com.viocha.alist_android/runtime_events"
        private const val DEFAULT_LOG_BYTES = 128 * 1024
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 2304
        private const val STORAGE_PERMISSION_REQUEST_CODE = 2305
    }
}
