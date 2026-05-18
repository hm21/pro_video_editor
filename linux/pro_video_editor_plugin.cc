#include "include/pro_video_editor/pro_video_editor_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <cstring>

#include "pro_video_editor_plugin_private.h"
#include "src/video_metadata.h"
#include "src/thumbnail_generator.h"

#define PRO_VIDEO_EDITOR_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), pro_video_editor_plugin_get_type(), \
                              ProVideoEditorPlugin))

struct _ProVideoEditorPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(ProVideoEditorPlugin, pro_video_editor_plugin, g_object_get_type())

// Forward declaration
static void pro_video_editor_plugin_handle_method_call(
    ProVideoEditorPlugin* self,
    FlMethodCall* method_call);

static void pro_video_editor_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(pro_video_editor_plugin_parent_class)->dispose(object);
}

static void pro_video_editor_plugin_class_init(ProVideoEditorPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = pro_video_editor_plugin_dispose;
}

static void pro_video_editor_plugin_init(ProVideoEditorPlugin* self) {}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  ProVideoEditorPlugin* plugin = PRO_VIDEO_EDITOR_PLUGIN(user_data);
  pro_video_editor_plugin_handle_method_call(plugin, method_call);
}

FlMethodResponse* get_platform_version() {
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar *version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void pro_video_editor_plugin_handle_method_call(
    ProVideoEditorPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "getPlatformVersion") == 0) {
    response = get_platform_version();
  } else if (strcmp(method, "getMetadata") == 0) {
    response = pro_video_editor::HandleGetMetadata(args);
  } else if (strcmp(method, "createVideoThumbnails") == 0) {
    response = pro_video_editor::HandleGenerateThumbnails(args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

void pro_video_editor_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  ProVideoEditorPlugin* plugin = PRO_VIDEO_EDITOR_PLUGIN(
      g_object_new(pro_video_editor_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "pro_video_editor",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
