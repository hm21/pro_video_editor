package ch.waio.pro_video_editor.src.shared.logging

import android.util.Log as AndroidLog

object PluginLog {
    private const val LEVEL_NONE = Int.MAX_VALUE

    @Volatile
    private var minimumPriority = defaultPriority()

    /**
     * Optional sink that forwards every emitted log entry to Flutter.
     *
     * Set by the plugin while a Dart listener is attached to the
     * `pro_video_editor_logs` event channel. The level string matches
     * `NativeLogLevel.methodValue` on the Dart side.
     */
    @Volatile
    var sink: ((level: String, tag: String, message: String, throwable: Throwable?) -> Unit)? = null

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

    private fun levelName(priority: Int): String {
        return when (priority) {
            AndroidLog.VERBOSE -> "verbose"
            AndroidLog.DEBUG -> "debug"
            AndroidLog.INFO -> "info"
            AndroidLog.WARN -> "warning"
            AndroidLog.ERROR -> "error"
            else -> "info"
        }
    }

    /**
     * Forwards an entry to the Dart [sink], if one is attached.
     *
     * Called only after the priority passed [shouldLog], so the Dart stream
     * is gated by the same level as the native console output.
     */
    private fun forward(priority: Int, tag: String, message: String, throwable: Throwable?) {
        sink?.invoke(levelName(priority), tag, message, throwable)
    }

    fun v(tag: String, message: String): Int {
        if (!shouldLog(AndroidLog.VERBOSE)) return 0
        forward(AndroidLog.VERBOSE, tag, message, null)
        return AndroidLog.v(tag, message)
    }

    fun d(tag: String, message: String): Int {
        if (!shouldLog(AndroidLog.DEBUG)) return 0
        forward(AndroidLog.DEBUG, tag, message, null)
        return AndroidLog.d(tag, message)
    }

    fun i(tag: String, message: String): Int {
        if (!shouldLog(AndroidLog.INFO)) return 0
        forward(AndroidLog.INFO, tag, message, null)
        return AndroidLog.i(tag, message)
    }

    fun w(tag: String, message: String): Int {
        if (!shouldLog(AndroidLog.WARN)) return 0
        forward(AndroidLog.WARN, tag, message, null)
        return AndroidLog.w(tag, message)
    }

    fun w(tag: String, message: String, throwable: Throwable): Int {
        if (!shouldLog(AndroidLog.WARN)) return 0
        forward(AndroidLog.WARN, tag, message, throwable)
        return AndroidLog.w(tag, message, throwable)
    }

    fun e(tag: String, message: String): Int {
        if (!shouldLog(AndroidLog.ERROR)) return 0
        forward(AndroidLog.ERROR, tag, message, null)
        return AndroidLog.e(tag, message)
    }

    fun e(tag: String, message: String, throwable: Throwable): Int {
        if (!shouldLog(AndroidLog.ERROR)) return 0
        forward(AndroidLog.ERROR, tag, message, throwable)
        return AndroidLog.e(tag, message, throwable)
    }
}