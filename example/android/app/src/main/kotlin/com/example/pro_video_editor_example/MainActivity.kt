package com.example.pro_video_editor_example

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ExampleVideoEffects.register()

        // Used by integration_test/content_uri_test.dart only: publishes a
        // local media file to MediaStore so the tests can feed the plugin a
        // real content:// URI, the kind the photo picker and SAF hand out.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_STORE_CHANNEL)
            .setMethodCallHandler { call, result ->
                val mainHandler = Handler(Looper.getMainLooper())
                when (call.method) {
                    "insert" -> Thread {
                        try {
                            val uri = insertIntoMediaStore(
                                path = call.argument<String>("path")!!,
                                mimeType = call.argument<String>("mimeType")!!,
                            )
                            mainHandler.post { result.success(uri) }
                        } catch (e: Exception) {
                            mainHandler.post { result.error("INSERT_FAILED", e.message, null) }
                        }
                    }.start()

                    "delete" -> {
                        val uri = call.argument<String>("uri")!!
                        result.success(contentResolver.delete(Uri.parse(uri), null, null))
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Copies [path] into a new MediaStore entry and returns its content URI,
     * or null below Android 10, where inserting needs a storage permission.
     */
    private fun insertIntoMediaStore(path: String, mimeType: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null

        val isAudio = mimeType.startsWith("audio/")
        val collection = if (isAudio) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val source = File(path)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, source.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(
                MediaStore.MediaColumns.RELATIVE_PATH,
                if (isAudio) "Music/ProVideoEditorTest" else "Movies/ProVideoEditorTest"
            )
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore insert returned null")
        try {
            contentResolver.openOutputStream(uri)!!.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
        } catch (e: Exception) {
            contentResolver.delete(uri, null, null)
            throw e
        }
        return uri.toString()
    }

    private companion object {
        const val MEDIA_STORE_CHANNEL = "pro_video_editor_example/media_store"
    }
}
