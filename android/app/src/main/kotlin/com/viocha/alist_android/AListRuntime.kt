package com.viocha.alist_android

import android.content.Context
import android.os.Build
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.io.RandomAccessFile
import java.util.Date
import java.util.Locale
import java.util.concurrent.TimeUnit

data class CommandResult(
    val success: Boolean,
    val message: String,
) {
    fun toMap(): Map<String, Any> {
        return mapOf(
            "success" to success,
            "message" to message,
        )
    }
}

data class RuntimePaths(
    val filesDir: String,
    val runtimeDir: String,
    val binaryPath: String,
    val dataDir: String,
    val configPath: String,
    val logPath: String,
    val primaryAbi: String,
    val supportedAbis: List<String>,
) {
    fun toMap(): Map<String, Any> {
        return mapOf(
            "filesDir" to filesDir,
            "runtimeDir" to runtimeDir,
            "binaryPath" to binaryPath,
            "dataDir" to dataDir,
            "configPath" to configPath,
            "logPath" to logPath,
            "primaryAbi" to primaryAbi,
            "supportedAbis" to supportedAbis,
        )
    }
}

fun interface RuntimeEventObserver {
    fun onEvent(event: Map<String, Any?>)
}

object AListRuntime {
    private val ansiEscapeRegex = Regex("""\u001B\[[0-9;?]*[ -/]*[@-~]""")
    private val disallowedControlRegex = Regex("""[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]""")
    private val logLevelPrefixRegex =
        Regex("""^(?:\[(?:stdout|stderr)\]\s+)?(?:INFO|WARN|ERRO|FATA|DEBU|TRAC|PANI)\[[^\]]+\]\s*""")

    @Volatile
    private var process: Process? = null

    @Volatile
    private var currentPort: Int? = null

    @Volatile
    private var startedAtEpochMs: Long? = null

    @Volatile
    private var lastExitCode: Int? = null

    @Volatile
    private var lastMessage: String = "AList has not been started yet."

    @Volatile
    private var stopRequested = false

    private val processLock = Any()
    private val eventObservers = LinkedHashSet<RuntimeEventObserver>()
    fun getPaths(context: Context): Map<String, Any> {
        return pathsFor(context).toMap()
    }

    fun addObserver(observer: RuntimeEventObserver) {
        synchronized(eventObservers) {
            eventObservers.add(observer)
        }
    }

    fun removeObserver(observer: RuntimeEventObserver) {
        synchronized(eventObservers) {
            eventObservers.remove(observer)
        }
    }

    fun getStatus(context: Context): Map<String, Any?> {
        val runtimePaths = pathsFor(context)
        val running = isRunning()
        return mapOf(
            "running" to running,
            "port" to currentPort,
            "startedAtEpochMs" to startedAtEpochMs,
            "lastExitCode" to lastExitCode,
            "lastMessage" to lastMessage,
            "binaryReady" to File(runtimePaths.binaryPath).canExecute(),
            "configExists" to File(runtimePaths.configPath).exists(),
            "logExists" to File(runtimePaths.logPath).exists(),
            "pid" to null,
            "paths" to runtimePaths.toMap(),
        )
    }

    fun readLogTail(context: Context, maxBytes: Int): String {
        val logFile = File(pathsFor(context).logPath)
        if (!logFile.exists()) {
            return ""
        }

        RandomAccessFile(logFile, "r").use { raf ->
            val fileLength = raf.length()
            val safeBytes = maxBytes.coerceAtLeast(1)
            val start = (fileLength - safeBytes).coerceAtLeast(0)
            raf.seek(start)
            val buffer = ByteArray((fileLength - start).toInt())
            raf.readFully(buffer)
            return String(buffer, Charsets.UTF_8)
        }
    }

    fun ensureBinaryExecutable(binaryPath: String): Boolean {
        val binaryFile = File(binaryPath)
        if (!binaryFile.exists()) {
            return false
        }
        if (binaryFile.canExecute()) {
            return true
        }
        binaryFile.setExecutable(true, false)
        return binaryFile.canExecute()
    }

    fun initializeDataDirectory(context: Context): CommandResult {
        val runtimePaths = pathsFor(context)
        ensureRuntimeDirectories(runtimePaths)
        val binaryFile = File(runtimePaths.binaryPath)
        if (!binaryFile.exists()) {
            return CommandResult(false, "AList runtime is missing. Please download it first.")
        }

        ensureBinaryExecutable(binaryFile.absolutePath)
        val command = listOf(
            binaryFile.absolutePath,
            "--data",
            runtimePaths.dataDir,
            "admin",
        )
        return runShortCommand(runtimePaths, command, "Initialized AList data directory.")
    }

    fun applyAdminPassword(context: Context, password: String): CommandResult {
        if (isRunning()) {
            return CommandResult(false, "Please stop the service before changing the admin password.")
        }

        val runtimePaths = pathsFor(context)
        ensureRuntimeDirectories(runtimePaths)
        val binaryFile = File(runtimePaths.binaryPath)
        if (!binaryFile.exists()) {
            return CommandResult(false, "AList runtime is missing. Please download it first.")
        }

        ensureBinaryExecutable(binaryFile.absolutePath)
        val command = listOf(
            binaryFile.absolutePath,
            "--data",
            runtimePaths.dataDir,
            "admin",
            "set",
            password,
        )
        return runShortCommand(runtimePaths, command, "Admin password updated.")
    }

    fun start(context: Context, port: Int, onExit: (Int) -> Unit): CommandResult {
        synchronized(processLock) {
            if (isRunning()) {
                emitStatus(context)
                return CommandResult(true, "AList is already running.")
            }

            val runtimePaths = pathsFor(context)
            ensureRuntimeDirectories(runtimePaths)
            val binaryFile = File(runtimePaths.binaryPath)
            if (!binaryFile.exists()) {
                lastMessage = "AList runtime is missing."
                emitStatus(context)
                return CommandResult(false, lastMessage)
            }

            ensureBinaryExecutable(binaryFile.absolutePath)

            val startCommand = listOf(
                binaryFile.absolutePath,
                "--data",
                runtimePaths.dataDir,
                "server",
            )

            return try {
                appendLog(runtimePaths, "Starting AList on port $port.")
                val processBuilder = ProcessBuilder(startCommand)
                    .directory(File(runtimePaths.runtimeDir))
                    .redirectErrorStream(false)
                process = processBuilder.start()
                currentPort = port
                startedAtEpochMs = System.currentTimeMillis()
                lastExitCode = null
                stopRequested = false
                lastMessage = "AList is running on port $port."
                emitStatus(context)

                pipeProcessStream(runtimePaths, process!!.inputStream, "stdout")
                pipeProcessStream(runtimePaths, process!!.errorStream, "stderr")
                waitForExit(context, process!!, runtimePaths, onExit)

                CommandResult(true, lastMessage)
            } catch (error: Exception) {
                appendLog(runtimePaths, "Failed to start AList: ${error.message}")
                lastMessage = "Failed to start AList: ${error.message}"
                process = null
                currentPort = null
                startedAtEpochMs = null
                emitStatus(context)
                CommandResult(false, lastMessage)
            }
        }
    }

    fun stop(context: Context): CommandResult {
        synchronized(processLock) {
            val runningProcess = process
            if (runningProcess == null || !runningProcess.isAlive) {
                process = null
                currentPort = null
                startedAtEpochMs = null
                lastMessage = "AList is already stopped."
                emitStatus(context)
                return CommandResult(true, lastMessage)
            }

            val runtimePaths = pathsFor(context)
            stopRequested = true
            appendLog(runtimePaths, "Stopping AList.")

            runningProcess.destroy()
            if (!runningProcess.waitFor(PROCESS_STOP_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                appendLog(runtimePaths, "AList did not stop in time. Forcing shutdown.")
                runningProcess.destroyForcibly()
            }

            process = null
            currentPort = null
            startedAtEpochMs = null
            lastMessage = "AList stopped."
            emitStatus(context)
            return CommandResult(true, lastMessage)
        }
    }

    private fun runShortCommand(
        runtimePaths: RuntimePaths,
        command: List<String>,
        successMessage: String,
    ): CommandResult {
        return try {
            appendLog(runtimePaths, "Executing: ${command.joinToString(" ")}")
            val processBuilder = ProcessBuilder(command)
                .directory(File(runtimePaths.runtimeDir))
                .redirectErrorStream(true)
            val shortProcess = processBuilder.start()
            val output = shortProcess.inputStream.bufferedReader().use { it.readText().trim() }
            val exitCode = shortProcess.waitFor()
            if (output.isNotBlank()) {
                appendLog(runtimePaths, output)
            }
            if (exitCode == 0) {
                lastMessage = successMessage
                CommandResult(true, successMessage)
            } else {
                val message = output.ifBlank { "Command failed with exit code $exitCode." }
                lastMessage = message
                CommandResult(false, message)
            }
        } catch (error: Exception) {
            val message = "Command failed: ${error.message}"
            appendLog(runtimePaths, message)
            lastMessage = message
            CommandResult(false, message)
        }
    }

    private fun waitForExit(
        context: Context,
        processToWatch: Process,
        runtimePaths: RuntimePaths,
        onExit: (Int) -> Unit,
    ) {
        Thread {
            val exitCode = processToWatch.waitFor()
            synchronized(processLock) {
                process = null
                currentPort = null
                startedAtEpochMs = null
                lastExitCode = exitCode
                lastMessage = if (stopRequested) {
                    "AList stopped."
                } else {
                    "AList exited with code $exitCode."
                }
                stopRequested = false
            }
            appendLog(runtimePaths, lastMessage)
            emitStatus(context)
            onExit(exitCode)
        }.start()
    }

    private fun pipeProcessStream(runtimePaths: RuntimePaths, inputStream: java.io.InputStream, label: String) {
        Thread {
            try {
                inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        appendLog(runtimePaths, "[$label] $line")
                    }
                }
            } catch (_: InterruptedIOException) {
                // The process streams are closed as part of a normal stop.
            } catch (_: IOException) {
                if (isRunning()) {
                    appendLog(runtimePaths, "[$label] stream closed unexpectedly.")
                }
            }
        }.start()
    }

    private fun isRunning(): Boolean {
        val activeProcess = process
        return activeProcess != null && activeProcess.isAlive
    }

    private fun pathsFor(context: Context): RuntimePaths {
        val filesDir = context.filesDir
        val runtimeDir = File(filesDir, "runtime")
        val dataDir = File(filesDir, "alist-data")
        val nativeLibraryDir = File(context.applicationInfo.nativeLibraryDir)
        val primaryAbi = Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"

        return RuntimePaths(
            filesDir = filesDir.absolutePath,
            runtimeDir = runtimeDir.absolutePath,
            binaryPath = File(nativeLibraryDir, "libalist.so").absolutePath,
            dataDir = dataDir.absolutePath,
            configPath = File(dataDir, "config.json").absolutePath,
            logPath = File(runtimeDir, "runtime.log").absolutePath,
            primaryAbi = primaryAbi,
            supportedAbis = Build.SUPPORTED_ABIS.toList(),
        )
    }

    private fun ensureRuntimeDirectories(runtimePaths: RuntimePaths) {
        File(runtimePaths.runtimeDir).mkdirs()
        File(runtimePaths.dataDir).mkdirs()
        File(runtimePaths.logPath).parentFile?.mkdirs()
    }

    private fun appendLog(runtimePaths: RuntimePaths, message: String) {
        val logFile = File(runtimePaths.logPath)
        logFile.parentFile?.mkdirs()
        val timestamp = java.text.SimpleDateFormat(
            "yyyy-MM-dd HH:mm:ss",
            Locale.US,
        ).format(Date())
        val sanitized = sanitizeLogText(message)
        if (sanitized.isBlank()) {
            return
        }
        val formatted = sanitized
            .lineSequence()
            .filter { it.isNotBlank() }
            .joinToString(separator = "\n") { "[$timestamp] $it" }
        if (formatted.isNotBlank()) {
            logFile.appendText("$formatted\n")
            emitEvent(
                mapOf(
                    "type" to "logs",
                    "logs" to formatted,
                ),
            )
        }
    }

    private fun emitStatus(context: Context) {
        emitEvent(
            mapOf(
                "type" to "status",
                "status" to getStatus(context.applicationContext),
            ),
        )
    }

    private fun emitEvent(event: Map<String, Any?>) {
        val observers =
            synchronized(eventObservers) {
                eventObservers.toList()
            }
        observers.forEach { observer ->
            observer.onEvent(event)
        }
    }

    private fun sanitizeLogText(message: String): String {
        return message
            .replace("\r\n", "\n")
            .replace('\r', '\n')
            .replace(ansiEscapeRegex, "")
            .replace(disallowedControlRegex, "")
            .lineSequence()
            .map { it.replace(logLevelPrefixRegex, "").trim() }
            .filter { it.isNotEmpty() }
            .joinToString(separator = "\n")
            .trim()
    }

    private const val PROCESS_STOP_TIMEOUT_SECONDS = 5L
}
