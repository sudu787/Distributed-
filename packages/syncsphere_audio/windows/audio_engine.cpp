// Media Foundation headers before the WASAPI ones (MinGW header order).
#include "media_decoder.h"

#include "audio_engine.h"

#include <avrt.h>
#include <propvarutil.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <condition_variable>
#include <cmath>

using Microsoft::WRL::ComPtr;

namespace syncsphere_audio {

namespace {
// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT (ksmedia.h), spelled out to keep the
// header set small.
const GUID kSubtypeFloat = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
// PKEY_Device_FriendlyName (functiondiscoverykeys_devpkey.h).
const PROPERTYKEY kDeviceFriendlyName = {
    {0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};
}  // namespace

int64_t NowNanos() {
  static const int64_t freq = [] {
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    return static_cast<int64_t>(f.QuadPart);
  }();
  LARGE_INTEGER c;
  QueryPerformanceCounter(&c);
  return CounterToNanos(static_cast<int64_t>(c.QuadPart), freq);
}

// ------------------------------------------------------------------ Segment

Segment::Segment(int id_, std::string uri_, std::string role_, int64_t start_us_)
    : id(id_), uri(std::move(uri_)), role(std::move(role_)), start_us(start_us_) {}

Segment::~Segment() { Cancel(); }

void Segment::Cancel() {
  cancel_ = true;
  if (worker_.joinable()) worker_.join();
}

void Segment::BeginDecode(DoneFn done, std::function<void(const std::string&)> on_error) {
  worker_ = std::thread([this, done = std::move(done), on_error = std::move(on_error)]() { Decode(done, on_error); });
}

bool Segment::Pull(float* frame2) {
  const size_t tail = tail_.load(std::memory_order_relaxed);
  if (head_.load(std::memory_order_acquire) == tail) return false;
  const size_t i = (tail % cap_frames_) * 2;
  frame2[0] = ring_[i];
  frame2[1] = ring_[i + 1];
  tail_.store(tail + 1, std::memory_order_release);
  return true;
}

void Segment::Decode(DoneFn done, std::function<void(const std::string&)> on_error) {
  MfScope mf;
  bool reported = false;
  auto report = [&](const std::string& err) {
    if (!reported) {
      reported = true;
      done(err);
    }
  };
  // A segment replaced before it was ready still answers its prepare call,
  // so the caller never waits forever.
  struct Answer {
    std::function<void()> fn;
    ~Answer() { fn(); }
  } answer{[&]() { report("prepare_error: superseded"); }};
  if (!mf.ok()) {
    eof_ = true;
    report("prepare_error: Media Foundation unavailable");
    return;
  }
  MediaDecoder dec;
  std::string err;
  if (!dec.Open(FileUriToPath(uri), &err) || (start_us > 0 && !dec.SeekExact(start_us, &err))) {
    eof_ = true;
    report("decode_error: " + err);
    return;
  }
  source_rate_ = dec.sample_rate();
  cap_frames_ = static_cast<size_t>(dec.sample_rate()) * 4;  // 4 s ahead
  ring_.assign(cap_frames_ * 2, 0.0f);
  const int ch = dec.channels();
  const std::vector<float> matrix = MixMatrix(role, ch);
  const size_t ready_frames = static_cast<size_t>(dec.sample_rate()) / 4;  // 250 ms buffered = ready
  std::vector<float> buf;
  while (!cancel_) {
    buf.clear();
    const size_t n = dec.Read(&buf, 4096, &err);
    if (n == 0) {
      eof_ = true;
      if (!err.empty()) {
        if (reported) on_error("decode_error: " + err);
        report("decode_error: " + err);
      }
      report("");
      return;
    }
    for (size_t f = 0; f < n && !cancel_; f++) {
      while (head_.load() - tail_.load(std::memory_order_acquire) >= cap_frames_) {
        if (cancel_) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
      const size_t head = head_.load(std::memory_order_relaxed);
      MixFrame(&buf[f * ch], ch, matrix, &ring_[(head % cap_frames_) * 2]);
      head_.store(head + 1, std::memory_order_release);
    }
    if (!reported && Available() >= ready_frames) report("");
  }
}

// ------------------------------------------------------- device notification

namespace {
class DeviceNotifier : public IMMNotificationClient {
 public:
  explicit DeviceNotifier(AudioEngine* engine) : engine_(engine) {}
  virtual ~DeviceNotifier() = default;
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG r = --refs_;
    if (r == 0) delete this;
    return r;
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IMMNotificationClient)) {
      *out = static_cast<IMMNotificationClient*>(this);
      AddRef();
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR) override {
    if (flow == eRender && role == eConsole) engine_->RequestReopen();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return S_OK; }

 private:
  AudioEngine* engine_;
  std::atomic<ULONG> refs_{1};
};
}  // namespace

// ------------------------------------------------------------------ Engine

AudioEngine::AudioEngine(EventFn on_event) : on_event_(std::move(on_event)) {
  wake_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
}

AudioEngine::~AudioEngine() {
  quit_ = true;
  if (wake_) SetEvent(wake_);
  if (thread_.joinable()) thread_.join();
  std::vector<std::shared_ptr<Segment>> all;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto& [id, s] : segments_) all.push_back(s);
    if (active_) all.push_back(active_);
    for (auto& s : retired_) all.push_back(s);
    segments_.clear();
    active_.reset();
    retired_.clear();
  }
  all.clear();  // joins decode threads outside the lock
  if (wake_) CloseHandle(wake_);
}

bool AudioEngine::Start(std::string* error) {
  if (running_) return true;
  quit_ = false;
  std::mutex m;
  std::condition_variable cv;
  bool done = false;
  bool ok = false;
  thread_ = std::thread([&, this]() {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    DWORD task = 0;
    HANDLE av = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task);
    std::string err;
    const bool opened = OpenDevice(&err);
    {
      std::lock_guard<std::mutex> lock(m);
      ok = opened;
      open_error_ = err;
      done = true;
    }
    cv.notify_all();
    if (opened) {
      running_ = true;
      RenderLoop();
    }
    CloseDevice();
    if (enumerator_ && notifier_) enumerator_->UnregisterEndpointNotificationCallback(notifier_.Get());
    notifier_.Reset();
    enumerator_.Reset();
    if (av) AvRevertMmThreadCharacteristics(av);
    if (SUCCEEDED(co)) CoUninitialize();
    running_ = false;
  });
  std::unique_lock<std::mutex> lock(m);
  cv.wait(lock, [&] { return done; });
  if (!ok) {
    *error = open_error_;
    lock.unlock();
    thread_.join();
  }
  return ok;
}

bool AudioEngine::OpenDevice(std::string* error) {
  HRESULT hr;
  if (!enumerator_) {
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator_));
    if (FAILED(hr)) {
      *error = HrMessage("no audio device enumerator", hr);
      return false;
    }
    notifier_.Attach(new DeviceNotifier(this));
    enumerator_->RegisterEndpointNotificationCallback(notifier_.Get());
  }
  ComPtr<IMMDevice> device;
  hr = enumerator_->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  if (FAILED(hr)) {
    *error = HrMessage("no audio output device", hr);
    return false;
  }
  std::string name;
  {
    ComPtr<IPropertyStore> props;
    if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &props))) {
      PROPVARIANT v;
      PropVariantInit(&v);
      if (SUCCEEDED(props->GetValue(kDeviceFriendlyName, &v)) && v.vt == VT_LPWSTR) name = WideToUtf8(v.pwszVal);
      PropVariantClear(&v);
    }
  }
  hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client_.ReleaseAndGetAddressOf()));
  if (FAILED(hr)) {
    *error = HrMessage("cannot open the audio device", hr);
    return false;
  }
  WAVEFORMATEX* mix = nullptr;
  hr = client_->GetMixFormat(&mix);
  if (FAILED(hr)) {
    *error = HrMessage("cannot read the device format", hr);
    client_.Reset();
    return false;
  }
  bool is_float = mix->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
  if (mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    const auto* ext = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mix);
    is_float = IsEqualGUID(ext->SubFormat, kSubtypeFloat) != 0;
  }
  if (!((is_float && mix->wBitsPerSample == 32) || (!is_float && mix->wBitsPerSample == 16))) {
    *error = "unsupported device format";
    CoTaskMemFree(mix);
    client_.Reset();
    return false;
  }
  // 20 ms buffer, event driven.
  hr = client_->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 200000, 0, mix, nullptr);
  const int rate = static_cast<int>(mix->nSamplesPerSec);
  channels_ = mix->nChannels;
  float_out_ = is_float;
  bits_ = mix->wBitsPerSample;
  CoTaskMemFree(mix);
  if (FAILED(hr)) {
    *error = HrMessage("cannot start the audio stream", hr);
    client_.Reset();
    return false;
  }
  client_->SetEventHandle(wake_);
  client_->GetBufferSize(&buffer_frames_);
  client_->GetService(IID_PPV_ARGS(&render_));
  client_->GetService(IID_PPV_ARGS(&clock_));
  if (!render_ || !clock_) {
    *error = "audio stream services unavailable";
    CloseDevice();
    return false;
  }
  clock_->GetFrequency(&clock_freq_);
  REFERENCE_TIME latency = 0;
  client_->GetStreamLatency(&latency);
  scratch_.assign(static_cast<size_t>(buffer_frames_) * 2, 0.0f);
  frame_base_ = written_;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    rate_hz_ = rate;
    latency_us_ = latency / 10;
    device_name_ = name;
    ref_frame_ = written_;
    ref_nanos_ = NowNanos();
  }
  // Prime with silence so the stream starts with a full buffer.
  BYTE* data = nullptr;
  if (SUCCEEDED(render_->GetBuffer(buffer_frames_, &data))) {
    render_->ReleaseBuffer(buffer_frames_, AUDCLNT_BUFFERFLAGS_SILENT);
    written_ += buffer_frames_;
  }
  hr = client_->Start();
  if (FAILED(hr)) {
    *error = HrMessage("cannot start the audio stream", hr);
    CloseDevice();
    return false;
  }
  return true;
}

void AudioEngine::CloseDevice() {
  if (client_) client_->Stop();
  clock_.Reset();
  render_.Reset();
  client_.Reset();
}

void AudioEngine::RenderLoop() {
  while (!quit_) {
    if (reopen_ || !client_) {
      reopen_ = false;
      CloseDevice();
      std::string err;
      if (!OpenDevice(&err)) {
        Emit("error", -1, NowNanos(), "audio device: " + err);
        for (int i = 0; i < 10 && !quit_; i++) std::this_thread::sleep_for(std::chrono::milliseconds(100));
        continue;
      }
    }
    WaitForSingleObject(wake_, 100);
    if (quit_) break;
    UINT32 padding = 0;
    HRESULT hr = client_->GetCurrentPadding(&padding);
    if (FAILED(hr)) {
      reopen_ = true;  // device removed or changed format
      continue;
    }
    const UINT32 avail = buffer_frames_ - padding;
    if (avail == 0) continue;
    UINT64 pos = 0, qpc = 0;
    int rate;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      rate = rate_hz_;
    }
    int64_t ref_frame, ref_nanos;
    if (SUCCEEDED(clock_->GetPosition(&pos, &qpc)) && clock_freq_ > 0) {
      ref_frame = frame_base_ + static_cast<int64_t>(static_cast<double>(pos) * rate / static_cast<double>(clock_freq_));
      ref_nanos = static_cast<int64_t>(qpc) * 100;
    } else {
      ref_frame = written_ - padding;
      ref_nanos = NowNanos();
    }
    BYTE* data = nullptr;
    hr = render_->GetBuffer(avail, &data);
    if (FAILED(hr)) {
      reopen_ = true;
      continue;
    }
    Render(scratch_.data(), written_, avail, ref_frame, ref_nanos);
    const float vol = volume_.load();
    if (float_out_) {
      float* out = reinterpret_cast<float*>(data);
      for (UINT32 f = 0; f < avail; f++) {
        const float l = scratch_[f * 2] * vol, r = scratch_[f * 2 + 1] * vol;
        float* o = out + static_cast<size_t>(f) * channels_;
        if (channels_ == 1) {
          o[0] = 0.5f * (l + r);
        } else {
          o[0] = l;
          o[1] = r;
          for (int c = 2; c < channels_; c++) o[c] = 0.0f;
        }
      }
    } else {
      int16_t* out = reinterpret_cast<int16_t*>(data);
      auto pcm = [](float v) {
        return static_cast<int16_t>(std::lround(std::max(-1.0f, std::min(1.0f, v)) * 32767.0f));
      };
      for (UINT32 f = 0; f < avail; f++) {
        const float l = scratch_[f * 2] * vol, r = scratch_[f * 2 + 1] * vol;
        int16_t* o = out + static_cast<size_t>(f) * channels_;
        if (channels_ == 1) {
          o[0] = pcm(0.5f * (l + r));
        } else {
          o[0] = pcm(l);
          o[1] = pcm(r);
          for (int c = 2; c < channels_; c++) o[c] = 0;
        }
      }
    }
    render_->ReleaseBuffer(avail, 0);
    written_ += avail;
  }
}

void AudioEngine::Render(float* out, int64_t first_frame, UINT32 frames, int64_t ref_frame, int64_t ref_nanos) {
  std::fill(out, out + static_cast<size_t>(frames) * 2, 0.0f);
  std::unique_lock<std::mutex> lock(mutex_);
  ref_frame_ = ref_frame;
  ref_nanos_ = ref_nanos;
  const int rate = rate_hz_;
  const int64_t end = first_frame + frames;

  // Where in this buffer a scheduled start or pause takes effect.
  int64_t switch_at = -1;
  std::shared_ptr<Segment> incoming;
  if (start_.set) {
    std::shared_ptr<Segment> seg;
    auto it = segments_.find(start_.segment);
    if (it != segments_.end()) seg = it->second;
    else if (active_ && active_->id == start_.segment) seg = active_;  // resume of a paused segment
    if (!seg) {
      Emit("error", start_.segment, NowNanos(), "segment is not prepared");
      start_.set = false;
    } else {
      int64_t f0 = FrameAt(start_.at_nanos, ref_nanos, ref_frame, rate);
      if (f0 < end) {
        f0 = std::max(f0, first_frame);
        switch_at = f0;
        incoming = seg;
        start_.set = false;
      }
    }
  }
  int64_t pause_at = -1;
  if (pause_.set && active_ && active_->id == pause_.segment) {
    const int64_t fp = std::max(FrameAt(pause_.at_nanos, ref_nanos, ref_frame, rate), first_frame);
    if (fp < end) pause_at = fp;
  } else if (pause_.set && (!active_ || active_->id != pause_.segment)) {
    pause_.set = false;  // that segment is gone
  }

  int64_t cursor = first_frame;
  auto render_active = [&](int64_t until) {
    if (until <= cursor) return;
    if (active_ && !active_->paused && !active_->ended) {
      RenderSegment(active_.get(), out + (cursor - first_frame) * 2, static_cast<UINT32>(until - cursor), cursor);
    }
    cursor = until;
  };

  if (pause_at >= 0 && (switch_at < 0 || pause_at <= switch_at)) {
    render_active(pause_at);
    Segment* s = active_.get();
    s->paused = true;
    // The resampler has rendered exactly up to the pause frame.
    s->paused_us = s->start_us + static_cast<int64_t>(s->resampler.SourcePosition() * 1e6 / s->source_rate());
    if (pause_.seek) s->reusable = false;
    Emit("paused", s->id, NanosAt(pause_at, ref_nanos, ref_frame, rate));
    pause_.set = false;
  }
  if (incoming) {
    render_active(switch_at);
    if (incoming != active_) {
      if (active_) RetireLocked(active_);
      segments_.erase(incoming->id);
      active_ = incoming;
      active_->started = true;
      active_->start_frame = switch_at;
      active_->rendered_frame = switch_at;
      active_->source_pos = 0;
    } else {
      // Resume where the pause left off; the device kept running meanwhile.
      active_->paused = false;
      active_->start_frame = switch_at;
      active_->rendered_frame = switch_at;
      active_->source_pos = active_->resampler.SourcePosition();
    }
    active_->step = static_cast<double>(active_->source_rate()) * rate_.load() / rate;
    Emit("playCalled", active_->id, NanosAt(switch_at, ref_nanos, ref_frame, rate));
  }
  render_active(end);
  if (active_ && !active_->paused) {
    active_->rendered_frame = end;
    active_->source_pos = active_->resampler.SourcePosition();
  }
}

void AudioEngine::RenderSegment(Segment* seg, float* out, UINT32 frames, int64_t first_frame) {
  int rate = rate_hz_;
  const double step = static_cast<double>(seg->source_rate()) * rate_.load() / rate;
  seg->step = step;
  const size_t needed = static_cast<size_t>(std::ceil(frames * step)) + 4;
  if (seg->Available() < needed && !seg->decoded_all()) {
    // Decoder behind (very rare for local files): play silence, keep the
    // track position, and let drift control resynchronise.
    if (!seg->stalled) {
      seg->stalled = true;
      Emit("stalled", seg->id, NanosAt(first_frame, ref_nanos_, ref_frame_, rate));
    }
    return;
  }
  if (seg->stalled) {
    seg->stalled = false;
    Emit("resumedAfterStall", seg->id, NanosAt(first_frame, ref_nanos_, ref_frame_, rate));
  }
  seg->resampler.Render([seg](float* f) { return seg->Pull(f); }, step, out, frames);
  if (seg->resampler.ended() && !seg->ended) {
    seg->ended = true;
    Emit("ended", seg->id, NanosAt(first_frame + frames, ref_nanos_, ref_frame_, rate));
  }
}

void AudioEngine::Emit(const std::string& kind, int segment, int64_t at_nanos, const std::string& message) {
  if (on_event_) on_event_(EngineEvent{kind, segment, at_nanos, message});
}

void AudioEngine::RetireLocked(std::shared_ptr<Segment> seg) {
  // Segments join their decode thread when destroyed; never do that on the
  // render thread. The next control call frees them.
  if (seg) retired_.push_back(std::move(seg));
}

std::map<std::string, std::string> AudioEngine::Describe() {
  std::lock_guard<std::mutex> lock(mutex_);
  return {{"deviceName", device_name_}, {"sampleRate", std::to_string(rate_hz_)}};
}

int AudioEngine::device_rate() {
  std::lock_guard<std::mutex> lock(mutex_);
  return rate_hz_;
}

int64_t AudioEngine::latency_us() {
  std::lock_guard<std::mutex> lock(mutex_);
  return latency_us_;
}

void AudioEngine::Prepare(int segment, const std::string& uri, int64_t position_us, Segment::DoneFn done) {
  std::vector<std::shared_ptr<Segment>> garbage;
  std::shared_ptr<Segment> seg;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    garbage.swap(retired_);
    // Resume optimisation: the paused active segment is already at the
    // requested position.
    if (active_ && active_->paused && active_->reusable && !active_->ended && active_->uri == uri &&
        active_->role == role_ && std::llabs(active_->paused_us - position_us) <= 2000) {
      for (auto& [id, s] : segments_) garbage.push_back(s);
      segments_.clear();
      active_->id = segment;
      seg = nullptr;
    } else {
      for (auto& [id, s] : segments_) garbage.push_back(s);
      segments_.clear();
      seg = std::make_shared<Segment>(segment, uri, role_, position_us);
      segments_[segment] = seg;
    }
  }
  garbage.clear();  // joins old decode threads outside the lock
  if (!seg) {
    done("");
    return;
  }
  const int id = segment;
  seg->BeginDecode(std::move(done), [this, id](const std::string& err) { Emit("error", id, NowNanos(), err); });
}

void AudioEngine::StartAt(int segment, int64_t at_nanos) {
  std::lock_guard<std::mutex> lock(mutex_);
  start_ = Pending{true, segment, at_nanos, false};
}

void AudioEngine::PauseAt(int segment, int64_t at_nanos, bool seek, int64_t) {
  std::lock_guard<std::mutex> lock(mutex_);
  pause_ = Pending{true, segment, at_nanos, seek};
}

void AudioEngine::SetRate(double rate) { rate_ = std::max(0.5, std::min(2.0, rate)); }

void AudioEngine::SetVolume(float volume) { volume_ = std::max(0.0f, std::min(1.0f, volume)); }

void AudioEngine::SetRole(const std::string& role) {
  std::lock_guard<std::mutex> lock(mutex_);
  role_ = role;
}

void AudioEngine::Stop() {
  std::vector<std::shared_ptr<Segment>> garbage;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    garbage.swap(retired_);
    for (auto& [id, s] : segments_) garbage.push_back(s);
    segments_.clear();
    if (active_) garbage.push_back(active_);
    active_.reset();
    start_ = Pending{};
    pause_ = Pending{};
  }
}

bool AudioEngine::Sample(PositionInfo* out) {
  std::lock_guard<std::mutex> lock(mutex_);
  Segment* s = active_.get();
  if (!s) return false;
  out->segment = s->id;
  out->at_nanos = ref_nanos_;
  out->rate = rate_.load();
  out->buffered_us = s->source_rate() > 0 ? static_cast<int64_t>(s->Available()) * 1000000 / s->source_rate() : 0;
  if (s->paused) {
    out->position_us = s->paused_us;
    out->playing = false;
    out->state = "ready";
  } else if (ref_frame_ < s->start_frame) {
    out->position_us = s->start_us;
    out->playing = false;
    out->state = "ready";
  } else {
    out->position_us = static_cast<int64_t>(
        TrackPositionUs(ref_frame_, s->rendered_frame, s->source_pos, s->source_rate(), s->step, s->start_us));
    out->playing = !s->ended;
    out->state = s->ended ? "ended" : (s->stalled ? "buffering" : "ready");
  }
  return true;
}

}  // namespace syncsphere_audio
