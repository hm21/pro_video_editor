package ch.waio.pro_video_editor

import ch.waio.pro_video_editor.src.shared.logging.PluginLog
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.test.BeforeTest
import kotlin.test.Test
import org.mockito.Mockito

/*
 * This demonstrates a simple unit test of the Kotlin portion of this plugin's implementation.
 *
 * Once you have built the plugin's example app, you can run these tests from the command
 * line by running `./gradlew testDebugUnitTest` in the `example/android/` directory, or
 * you can run them directly from IDEs that support JUnit such as Android Studio.
 */

internal class ProVideoEditorPluginTest {

  @BeforeTest
  fun silenceNativeLogging() {
    // PluginLog forwards to android.util.Log, which is not mocked in plain JVM
    // unit tests. Muting it keeps these tests free of "not mocked" failures.
    PluginLog.setMinimumLevel("none")
  }

  @Test
  fun onMethodCall_getPlatformVersion_returnsExpectedValue() {
    val plugin = ProVideoEditorPlugin()

    val call = MethodCall("getPlatformVersion", null)
    val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
    plugin.onMethodCall(call, mockResult)

    Mockito.verify(mockResult).success("Android " + android.os.Build.VERSION.RELEASE)
  }

  @Test
  fun cancelTask_forUnknownId_returnsTaskNotFound() {
    val plugin = ProVideoEditorPlugin()

    val cancelResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
    plugin.onMethodCall(MethodCall("cancelTask", mapOf("id" to "missing-task")), cancelResult)

    // Cancelling an id that maps to no active task is a TASK_NOT_FOUND error.
    // The render/cancel race (a cancel that races ahead of its start) is handled
    // in the shared Dart layer before the request reaches native, so native can
    // keep this strict contract for genuinely unknown ids.
    Mockito.verify(cancelResult)
      .error(Mockito.eq("TASK_NOT_FOUND"), Mockito.any(), Mockito.any())
    Mockito.verify(cancelResult, Mockito.never()).success(Mockito.any())
  }
}
