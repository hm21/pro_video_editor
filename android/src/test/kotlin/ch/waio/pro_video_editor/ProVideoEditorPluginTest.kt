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
  fun cancelTask_forUnknownId_isSafeNoOpNotTaskNotFound() {
    val plugin = ProVideoEditorPlugin()

    val cancelResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
    plugin.onMethodCall(MethodCall("cancelTask", mapOf("id" to "missing-task")), cancelResult)

    // A cancel that arrives before its task is registered must be a no-op, never
    // a TASK_NOT_FOUND error (that error used to surface to the Dart layer when a
    // cancel raced ahead of the render start).
    Mockito.verify(cancelResult).success(true)
    Mockito.verify(cancelResult, Mockito.never())
      .error(Mockito.eq("TASK_NOT_FOUND"), Mockito.any(), Mockito.any())
  }

  @Test
  fun renderVideo_afterCancelBeforeRegister_reportsCanceledWithoutStarting() {
    val plugin = ProVideoEditorPlugin()
    val id = "render-1"

    // 1) Cancel arrives first (the Dart layer awaits async work before invoking
    //    renderVideo, so this ordering happens in practice).
    val cancelResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
    plugin.onMethodCall(MethodCall("cancelTask", mapOf("id" to id)), cancelResult)
    Mockito.verify(cancelResult).success(true)

    // 2) The render then registers and must immediately resolve as CANCELED,
    //    without starting an un-cancellable native job. The render service is
    //    never touched because the pending cancel is consumed first.
    val renderResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
    val args = mapOf(
      "id" to id,
      "videoClips" to listOf(mapOf("inputPath" to "/does/not/matter.mp4")),
      "outputFormat" to "mp4",
    )
    plugin.onMethodCall(MethodCall("renderVideo", args), renderResult)

    Mockito.verify(renderResult).error(Mockito.eq("CANCELED"), Mockito.any(), Mockito.any())
    Mockito.verify(renderResult, Mockito.never()).success(Mockito.any())
  }

  @Test
  fun renderVideo_withoutPendingCancel_consumesOnlyMatchingId() {
    val plugin = ProVideoEditorPlugin()

    // A pending cancel for one id must not cancel a render with a different id.
    val cancelResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
    plugin.onMethodCall(MethodCall("cancelTask", mapOf("id" to "other-id")), cancelResult)
    Mockito.verify(cancelResult).success(true)

    val renderResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
    val args = mapOf(
      "id" to "render-2",
      "videoClips" to listOf(mapOf("inputPath" to "/does/not/matter.mp4")),
      "outputFormat" to "mp4",
    )
    plugin.onMethodCall(MethodCall("renderVideo", args), renderResult)

    // This render is not pre-canceled, so it must not be answered with CANCELED.
    Mockito.verify(renderResult, Mockito.never())
      .error(Mockito.eq("CANCELED"), Mockito.any(), Mockito.any())
  }
}
