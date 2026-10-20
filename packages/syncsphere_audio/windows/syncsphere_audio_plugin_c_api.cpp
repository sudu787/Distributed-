#include "include/syncsphere_audio/syncsphere_audio_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "syncsphere_audio_plugin.h"

void SyncsphereAudioPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  syncsphere_audio::SyncsphereAudioPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
