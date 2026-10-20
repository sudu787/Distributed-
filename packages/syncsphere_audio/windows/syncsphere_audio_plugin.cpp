// Media Foundation headers before the WASAPI ones (MinGW header order).
#include "media_decoder.h"

#include "syncsphere_audio_plugin.h"

#include <windows.h>

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <deque>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

namespace syncsphere_audio {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = flutter::MethodResult<EncodableValue>;

// Runs callbacks from engine and worker threads on the platform thread
// (method results and channel events must be sent from there).
class Dispatcher {
 public:
  explicit Dispatcher(UINT message) : message_(message) {}

  void SetWindow(HWND hwnd) {
    std::lock_guard<std::mutex> lock(mutex_);
    hwnd_ = hwnd;
  }

  void Post(std::function<void()> task) {
    HWND hwnd;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (closed_) return;
      queue_.push_back(std::move(task));
      hwnd = hwnd_;
    }
    if (hwnd) PostMessageW(hwnd, message_, 0, 0);
  }

  void Drain() {
    std::deque<std::function<void()>> tasks;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      tasks.swap(queue_);
    }
    for (auto& t : tasks) t();
  }

  void Close() {
    std::lock_guard<std::mutex> lock(mutex_);
    closed_ = true;
    queue_.clear();
  }

  UINT message() const { return message_; }

 private:
  const UINT message_;
  std::mutex mutex_;
  std::deque<std::function<void()>> queue_;
  HWND hwnd_ = nullptr;
  bool closed_ = false;
};

namespace {

const EncodableMap* Args(const flutter::MethodCall<EncodableValue>& call) {
  return std::get_if<EncodableMap>(call.arguments());
}

const EncodableValue* Arg(const EncodableMap* m, const char* key) {
  if (!m) return nullptr;
  auto it = m->find(EncodableValue(key));
  return it == m->end() ? nullptr : &it->second;
}

std::optional<int64_t> ArgInt(const EncodableMap* m, const char* key) {
  const EncodableValue* v = Arg(m, key);
  if (!v) return std::nullopt;
  if (auto i = std::get_if<int32_t>(v)) return *i;
  if (auto l = std::get_if<int64_t>(v)) return *l;
  if (auto d = std::get_if<double>(v)) return static_cast<int64_t>(*d);
  return std::nullopt;
}

std::optional<double> ArgDouble(const EncodableMap* m, const char* key) {
  const EncodableValue* v = Arg(m, key);
  if (!v) return std::nullopt;
  if (auto d = std::get_if<double>(v)) return *d;
  if (auto i = std::get_if<int32_t>(v)) return *i;
  if (auto l = std::get_if<int64_t>(v)) return static_cast<double>(*l);
  return std::nullopt;
}

std::string ArgString(const EncodableMap* m, const char* key) {
  const EncodableValue* v = Arg(m, key);
  if (!v) return std::string();
  if (auto s = std::get_if<std::string>(v)) return *s;
  return std::string();
}

bool ArgBool(const EncodableMap* m, const char* key) {
  const EncodableValue* v = Arg(m, key);
  if (!v) return false;
  if (auto b = std::get_if<bool>(v)) return *b;
  return false;
}

HWND RootWindow(flutter::PluginRegistrarWindows* registrar) {
  flutter::FlutterView* view = registrar->GetView();
  return view ? GetAncestor(view->GetNativeWindow(), GA_ROOT) : nullptr;
}

}  // namespace

// static
void SyncsphereAudioPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<SyncsphereAudioPlugin>(registrar);
  auto* p = plugin.get();

  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "dev.syncsphere/audio", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [p](const auto& call, auto result) { p->HandleMethodCall(call, std::move(result)); });

  auto events = std::make_unique<flutter::EventChannel<EncodableValue>>(
      registrar->messenger(), "dev.syncsphere/audio_events", &flutter::StandardMethodCodec::GetInstance());
  events->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [p](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        p->SetSink(std::move(sink));
        return nullptr;
      },
      [p](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        p->SetSink(nullptr);
        return nullptr;
      }));

  // The channels live as long as the plugin (the registrar keeps it).
  p->channel_ = std::move(channel);
  p->events_ = std::move(events);
  registrar->AddPlugin(std::move(plugin));
}

SyncsphereAudioPlugin::SyncsphereAudioPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      dispatcher_(std::make_shared<Dispatcher>(RegisterWindowMessageW(L"SyncSphereAudioDispatch"))),
      sink_(std::make_shared<std::unique_ptr<flutter::EventSink<EncodableValue>>>()) {
  auto d = dispatcher_;
  proc_delegate_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [d](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
        if (message == d->message()) {
          d->Drain();
          return 0;
        }
        return std::nullopt;
      });
  dispatcher_->SetWindow(RootWindow(registrar_));
}

SyncsphereAudioPlugin::~SyncsphereAudioPlugin() {
  dispatcher_->Close();
  engine_.reset();
  registrar_->UnregisterTopLevelWindowProcDelegate(proc_delegate_);
  SetThreadExecutionState(ES_CONTINUOUS);
}

void SyncsphereAudioPlugin::SetSink(std::unique_ptr<flutter::EventSink<EncodableValue>> sink) {
  *sink_ = std::move(sink);
}

AudioEngine& SyncsphereAudioPlugin::engine() {
  if (!engine_) {
    auto d = dispatcher_;
    auto sink = sink_;
    engine_ = std::make_unique<AudioEngine>([d, sink](const EngineEvent& e) {
      d->Post([sink, e]() {
        if (!*sink) return;
        EncodableMap m{{EncodableValue("kind"), EncodableValue(e.kind)},
                       {EncodableValue("segment"), EncodableValue(e.segment)},
                       {EncodableValue("atNanos"), EncodableValue(e.at_nanos)},
                       {EncodableValue("message"), e.message.empty() ? EncodableValue() : EncodableValue(e.message)}};
        (*sink)->Success(EncodableValue(m));
      });
    });
  }
  return *engine_;
}

void SyncsphereAudioPlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call,
                                             std::unique_ptr<Result> result) {
  const std::string& name = call.method_name();
  const EncodableMap* args = Args(call);
  dispatcher_->SetWindow(RootWindow(registrar_));

  if (name == "nowNanos") {
    result->Success(EncodableValue(NowNanos()));
  } else if (name == "init") {
    std::string err;
    if (!engine().Start(&err)) {
      result->Error("init_failed", err);
      return;
    }
    auto info = engine().Describe();
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("backend"), EncodableValue("wasapi-windows")},
        {EncodableValue("rateControl"), EncodableValue(true)},
        {EncodableValue("minRate"), EncodableValue(0.5)},
        {EncodableValue("maxRate"), EncodableValue(2.0)},
        {EncodableValue("outputLatencyHintUs"), EncodableValue(engine().latency_us())},
        {EncodableValue("sampleRate"), EncodableValue(engine().device_rate())},
        {EncodableValue("deviceName"), EncodableValue(info["deviceName"])},
        {EncodableValue("bluetoothOutputPresent"), EncodableValue(false)},
    }));
  } else if (name == "prepare") {
    const auto segment = ArgInt(args, "segment");
    const std::string uri = ArgString(args, "uri");
    if (!segment || uri.empty()) {
      result->Error("bad_args", "segment and uri required");
      return;
    }
    std::shared_ptr<Result> shared(result.release());
    auto d = dispatcher_;
    engine().Prepare(static_cast<int>(*segment), uri, ArgInt(args, "positionUs").value_or(0),
                     [d, shared](const std::string& err) {
                       d->Post([shared, err]() {
                         if (err.empty()) shared->Success();
                         else shared->Error("prepare_failed", err);
                       });
                     });
  } else if (name == "startAt") {
    engine().StartAt(static_cast<int>(ArgInt(args, "segment").value_or(-1)), ArgInt(args, "atNanos").value_or(0));
    result->Success();
  } else if (name == "pauseAt") {
    const auto seek = ArgInt(args, "seekToUs");
    engine().PauseAt(static_cast<int>(ArgInt(args, "segment").value_or(-1)), ArgInt(args, "atNanos").value_or(0),
                     seek.has_value(), seek.value_or(0));
    result->Success();
  } else if (name == "setRate") {
    engine().SetRate(ArgDouble(args, "rate").value_or(1.0));
    result->Success();
  } else if (name == "setVolume") {
    engine().SetVolume(static_cast<float>(ArgDouble(args, "volume").value_or(1.0)));
    result->Success();
  } else if (name == "setChannelRole") {
    const std::string role = ArgString(args, "role");
    static const char* kRoles[] = {"stereo", "left", "right", "mono", "center", "surroundLeft", "surroundRight"};
    bool known = false;
    for (const char* r : kRoles) known = known || role == r;
    if (!known) {
      result->Error("bad_args", "unknown role " + role);
      return;
    }
    engine().SetRole(role);
    result->Success();
  } else if (name == "stop") {
    if (engine_) engine_->Stop();
    result->Success();
  } else if (name == "sample") {
    PositionInfo p;
    if (!engine_ || !engine_->Sample(&p)) {
      result->Success();
      return;
    }
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("segment"), EncodableValue(p.segment)},
        {EncodableValue("positionUs"), EncodableValue(p.position_us)},
        {EncodableValue("atNanos"), EncodableValue(p.at_nanos)},
        {EncodableValue("playing"), EncodableValue(p.playing)},
        {EncodableValue("bufferedUs"), EncodableValue(p.buffered_us)},
        {EncodableValue("rate"), EncodableValue(p.rate)},
        {EncodableValue("state"), EncodableValue(p.state)},
    }));
  } else if (name == "acquireNetworkLocks") {
    result->Success(EncodableValue(EncodableMap{}));
  } else if (name == "releaseNetworkLocks" || name == "startService" || name == "stopService") {
    result->Success();
  } else if (name == "updateService") {
    result->Success(EncodableValue(false));
  } else if (name == "keepScreenOn") {
    const bool on = ArgBool(args, "on");
    SetThreadExecutionState(on ? (ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED) : ES_CONTINUOUS);
    result->Success(EncodableValue(true));
  } else if (name == "moveToBack") {
    HWND root = RootWindow(registrar_);
    if (root) ShowWindow(root, SW_MINIMIZE);
    result->Success(EncodableValue(root != nullptr));
  } else if (name == "requestPermission") {
    // No microphone capture on Windows yet; everything else needs no prompt.
    result->Success(EncodableValue(ArgString(args, "name") != "microphone"));
  } else if (name == "recordMic") {
    result->Error("not_supported", "microphone calibration is not available on Windows yet");
  } else if (name == "extractArtwork") {
    result->Success(EncodableValue(false));
  } else if (name == "probe" || name == "exactCopy") {
    const std::string path = FileUriToPath(ArgString(args, "uri"));
    const std::string out = ArgString(args, "out");
    std::shared_ptr<Result> shared(result.release());
    auto d = dispatcher_;
    const bool copy = name == "exactCopy";
    std::thread([d, shared, path, out, copy]() {
      MfScope mf;
      std::string err;
      if (copy) {
        int rate = 0, ch = 0;
        int64_t dur = 0;
        const bool ok = mf.ok() && DecodeToWav(path, out, &rate, &ch, &dur, &err);
        d->Post([shared, ok, err, out, rate, ch, dur]() {
          if (!ok) {
            shared->Error("transcode_failed", err.empty() ? "decoder unavailable" : err);
            return;
          }
          shared->Success(EncodableValue(EncodableMap{
              {EncodableValue("path"), EncodableValue(out)},
              {EncodableValue("sampleRate"), EncodableValue(rate)},
              {EncodableValue("channels"), EncodableValue(ch)},
              {EncodableValue("durationUs"), EncodableValue(dur)},
              {EncodableValue("decoder"), EncodableValue("media-foundation")},
          }));
        });
      } else {
        int64_t duration_ms = -1;
        auto tags = ProbeFile(path, &duration_ms, &err);
        d->Post([shared, tags, duration_ms]() {
          EncodableMap m;
          if (duration_ms >= 0) m[EncodableValue("durationMs")] = EncodableValue(duration_ms);
          for (const auto& [k, v] : tags) m[EncodableValue(k)] = EncodableValue(v);
          shared->Success(EncodableValue(m));
        });
      }
    }).detach();
  } else if (name == "queryAudio" || name == "takeSharedAudio") {
    result->Success(EncodableValue(EncodableList{}));
  } else if (name == "copyContent") {
    result->Error("not_supported", "no phone library on Windows");
  } else {
    result->NotImplemented();
  }
}

}  // namespace syncsphere_audio
