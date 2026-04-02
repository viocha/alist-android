package com.viocha.alist_android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null
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
            "requestNotificationPermission" -> requestNotificationPermission(result)
            "startService" -> {
                val port = call.argument<Int>("port") ?: 5244
                val password = call.argument<String>("password") ?: ""
                val intent = Intent(applicationContext, AListForegroundService::class.java).apply {
                    action = AListForegroundService.ACTION_START
                    putExtra(AListForegroundService.EXTRA_PORT, port)
                    putExtra(AListForegroundService.EXTRA_PASSWORD, password)
                }
                ContextCompat.startForegroundService(applicationContext, intent)
                result.success(
                    mapOf(
                        "success" to true,
                        "message" to "Foreground service start requested.",
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

        if (requestCode != NOTIFICATION_PERMISSION_REQUEST_CODE) {
            return
        }

        val granted =
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(
            mapOf(
                "success" to granted,
                "message" to if (granted) {
                    "Notification permission granted."
                } else {
                    "需要通知权限才能显示常驻服务通知。"
                },
            ),
        )
        pendingPermissionResult = null
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

        if (pendingPermissionResult != null) {
            result.success(
                mapOf(
                    "success" to false,
                    "message" to "A permission request is already in progress.",
                ),
            )
            return
        }

        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
    }

    companion object {
        private const val CHANNEL_NAME = "com.viocha.alist_android/runtime"
        private const val EVENTS_CHANNEL_NAME = "com.viocha.alist_android/runtime_events"
        private const val DEFAULT_LOG_BYTES = 128 * 1024
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 2304
    }
}
