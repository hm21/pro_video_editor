//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <audioplayers_windows/audioplayers_windows_plugin.h>
#include <fvp/fvp_plugin_c_api.h>
#include <pro_video_editor/pro_video_editor_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  AudioplayersWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AudioplayersWindowsPlugin"));
  FvpPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FvpPluginCApi"));
  ProVideoEditorPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ProVideoEditorPluginCApi"));
}
