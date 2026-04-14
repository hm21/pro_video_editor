package ch.waio.pro_video_editor.src.shared.logging

import android.util.Log as AndroidLog

object PluginLog {
    private const val LEVEL_NONE = Int.MAX_VALUE

    @Volatile
    private var minimumPriority = defaultPriority()

    fun setMinimumLevel(level: String) {
        minimumPriority = parsePriority(level)
    }

    private fun defaultPriority(): Int {
        val isDebugBuild = runCatching {
            Class.forName("ch.waio.pro_video_editor.BuildConfig")
                .getField("DEBUG")
                .getBoolean(null)
        }.getOrDefault(true)

        return if (isDebugBuild) AndroidLog.DEBUG else AndroidLog.WARN
    }

    private fun parsePriority(level: String): Int {
        return when (level.lowercase()) {
            "none" -> LEVEL_NONE
            "error" -> AndroidLog.ERROR
            "warn", "warning" -> AndroidLog.WARN
            "info" -> AndroidLog.INFO
            "debug" -> AndroidLog.DEBUG
            "verbose" -> AndroidLog.VERBOSE
            else -> throw IllegalArgumentException("Unsupported Android log level: $level")
        }
    }

    private fun shouldLog(priority: Int): Boolean {
        return priority >= minimumPriority
    }

    fun v(tag: String, message: String): Int {
        return if (shouldLog(AndroidLog.VERBOSE)) AndroidLog.v(tag, message) else 0
    }

    fun d(tag: String, message: String): Int {
        return if (shouldLog(AndroidLog.DEBUG)) AndroidLog.d(tag, message) else 0
    }

    fun i(tag: String, message: String): Int {
        return if (shouldLog(AndroidLog.INFO)) AndroidLog.i(tag, message) else 0
    }

    fun w(tag: String, message: String): Int {
        return if (shouldLog(AndroidLog.WARN)) AndroidLog.w(tag, message) else 0
    }

    fun w(tag: String, message: String, throwable: Throwable): Int {
        return if (shouldLog(AndroidLog.WARN)) AndroidLog.w(tag, message, throwable) else 0
    }

    fun e(tag: String, message: String): Int {
        return if (shouldLog(AndroidLog.ERROR)) AndroidLog.e(tag, message) else 0
    }

    fun e(tag: String, message: String, throwable: Throwable): Int {
        return if (shouldLog(AndroidLog.ERROR)) AndroidLog.e(tag, message, throwable) else 0
    }
}