// Windows playback engine for SyncSphere: WASAPI shared-mode output that
// starts a segment at an exact performance-counter instant, varies the
// playback rate for drift correction, and reports the track position of the
// frame the device is playing (IAudioClock), like SyncAudioEngine.kt does
// with Media3 on Android.
#ifndef SYNCSPHERE_AUDIO_AUDIO_ENGINE_H_
#define SYNCSPHERE_AUDIO_AUDIO_ENGINE_H_

#include <windows.h>

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "render_math.h"

namespace syncsphere_audio {

// System.nanoTime() equivalent: QueryPerformanceCounter in nanoseconds.
int64_t NowNanos();

struct EngineEvent {
  std::string kind;  // playCalled, paused, stalled, resumedAfterStall, ended, error
  int segment = -1;
  int64_t at_nanos = 0;
  std::string message;
};

struct PositionInfo {
  int segment = -1;
  int64_t position_us = 0;
  int64_t at_nanos = 0;
  bool playing = false;
  int64_t buffered_us = 0;
  double rate = 1.0;
  std::string state;
};

// One prepared stretch of a track: decodes on its own thread into a ring
// buffer (channel role already applied) that the render thread drains.
class Segment {
 public:
  using DoneFn = std::function<void(const std::string& error)>;
  Segment(int id, std::string uri, std::string role, int64_t start_us);
  ~Segment();
  Segment(const Segment&) = delete;
  Segment& operator=(const Segment&) = delete;

  void BeginDecode(DoneFn done, std::function<void(const std::string&)> on_error);
  void Cancel();

  size_t Available() const { return head_.load() - tail_.load(); }
  bool Pull(float* frame2);
  bool decoded_all() const { return eof_.load(); }
  int source_rate() const { return source_rate_.load(); }

  // Guarded by the engine mutex.
  int id;
  const std::string uri;
  const std::string role;
  const int64_t start_us;
  bool started = false;
  int64_t start_frame = 0;  // device frame where its audio began
  bool paused = false;
  int64_t paused_us = 0;
  bool reusable = true;  // false after a pause that also seeks
  bool stalled = false;
  bool ended = false;
  StereoResampler resampler;
  // Position bookkeeping at the end of the last rendered buffer.
  int64_t rendered_frame = 0;
  double source_pos = 0;
  double step = 1.0;

 private:
  void Decode(DoneFn done, std::function<void(const std::string&)> on_error);

  std::vector<float> ring_;
  size_t cap_frames_ = 0;
  std::atomic<size_t> head_{0};
  std::atomic<size_t> tail_{0};
  std::atomic<bool> cancel_{false};
  std::atomic<bool> eof_{false};
  std::atomic<int> source_rate_{48000};
  std::thread worker_;
};

class AudioEngine {
 public:
  using EventFn = std::function<void(const EngineEvent&)>;
  explicit AudioEngine(EventFn on_event);
  ~AudioEngine();

  // Opens the default output device and starts the render thread (once).
  bool Start(std::string* error);
  std::map<std::string, std::string> Describe();
  int device_rate();
  int64_t latency_us();

  void Prepare(int segment, const std::string& uri, int64_t position_us, Segment::DoneFn done);
  void StartAt(int segment, int64_t at_nanos);
  void PauseAt(int segment, int64_t at_nanos, bool seek, int64_t seek_to_us);
  void SetRate(double rate);
  void SetVolume(float volume);
  void SetRole(const std::string& role);
  void Stop();
  bool Sample(PositionInfo* out);

  // Called by the device notification client.
  void RequestReopen() { reopen_ = true; }

 private:
  struct Pending {
    bool set = false;
    int segment = -1;
    int64_t at_nanos = 0;
    bool seek = false;
  };

  void RenderLoop();
  bool OpenDevice(std::string* error);
  void CloseDevice();
  void Render(float* out, int64_t first_frame, UINT32 frames, int64_t ref_frame, int64_t ref_nanos);
  void RenderSegment(Segment* seg, float* out, UINT32 frames, int64_t first_frame);
  void Emit(const std::string& kind, int segment, int64_t at_nanos, const std::string& message = "");
  void RetireLocked(std::shared_ptr<Segment> seg);

  EventFn on_event_;
  std::mutex mutex_;
  std::map<int, std::shared_ptr<Segment>> segments_;  // standby (prepared) segments
  std::shared_ptr<Segment> active_;
  std::vector<std::shared_ptr<Segment>> retired_;
  Pending start_;
  Pending pause_;
  std::string role_ = "stereo";
  std::atomic<double> rate_{1.0};
  std::atomic<float> volume_{1.0f};

  // Device (render thread, plus snapshot fields under mutex_).
  std::thread thread_;
  std::atomic<bool> quit_{false};
  std::atomic<bool> running_{false};
  std::atomic<bool> reopen_{false};
  HANDLE wake_ = nullptr;
  Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator_;
  Microsoft::WRL::ComPtr<IMMNotificationClient> notifier_;
  Microsoft::WRL::ComPtr<IAudioClient> client_;
  Microsoft::WRL::ComPtr<IAudioRenderClient> render_;
  Microsoft::WRL::ComPtr<IAudioClock> clock_;
  UINT32 buffer_frames_ = 0;
  UINT64 clock_freq_ = 1;
  int channels_ = 2;
  bool float_out_ = true;
  int bits_ = 32;
  int64_t written_ = 0;     // device frames written since the engine started
  int64_t frame_base_ = 0;  // written_ when the current device was opened
  std::vector<float> scratch_;
  int rate_hz_ = 48000;            // guarded by mutex_
  int64_t latency_us_ = 0;         // guarded by mutex_
  std::string device_name_;        // guarded by mutex_
  int64_t ref_frame_ = 0;          // guarded by mutex_: device frame playing at ref_nanos_
  int64_t ref_nanos_ = 0;
  std::string open_error_;
};

}  // namespace syncsphere_audio

#endif  // SYNCSPHERE_AUDIO_AUDIO_ENGINE_H_
