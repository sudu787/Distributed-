#ifndef FLUTTER_PLUGIN_SYNCSPHERE_AUDIO_PLUGIN_H_
#define FLUTTER_PLUGIN_SYNCSPHERE_AUDIO_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

#include "audio_engine.h"

namespace syncsphere_audio {

class Dispatcher;

// Windows side of the `dev.syncsphere/audio` channel: the same methods as
// SyncsphereAudioPlugin.kt, backed by AudioEngine (WASAPI + Media
// Foundation). Phone-only features (notification service, microphone,
// MediaStore, share intents) answer with neutral values.
class SyncsphereAudioPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit SyncsphereAudioPlugin(flutter::PluginRegistrarWindows* registrar);
  virtual ~SyncsphereAudioPlugin();

  SyncsphereAudioPlugin(const SyncsphereAudioPlugin&) = delete;
  SyncsphereAudioPlugin& operator=(const SyncsphereAudioPlugin&) = delete;

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void SetSink(std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink);

 private:
  AudioEngine& engine();

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::shared_ptr<Dispatcher> dispatcher_;
  std::unique_ptr<AudioEngine> engine_;
  std::shared_ptr<std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>> sink_;
  int proc_delegate_ = 0;
};

}  // namespace syncsphere_audio

#endif  // FLUTTER_PLUGIN_SYNCSPHERE_AUDIO_PLUGIN_H_
