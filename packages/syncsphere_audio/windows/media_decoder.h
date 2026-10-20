// Media Foundation decoding of local files to 32-bit float PCM, with
// sample-exact seeking (coarse seek, then decode and discard by timestamp).
#ifndef SYNCSPHERE_AUDIO_MEDIA_DECODER_H_
#define SYNCSPHERE_AUDIO_MEDIA_DECODER_H_

#include <windows.h>

#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace syncsphere_audio {

std::wstring Utf8ToWide(const std::string& s);
std::string WideToUtf8(const std::wstring& s);
std::string HrMessage(const char* what, HRESULT hr);

class MediaDecoder {
 public:
  MediaDecoder() = default;
  MediaDecoder(const MediaDecoder&) = delete;
  MediaDecoder& operator=(const MediaDecoder&) = delete;

  // Opens a local file (UTF-8 path). The calling thread must have COM and
  // Media Foundation started (see MfScope).
  bool Open(const std::string& path, std::string* error);

  int sample_rate() const { return sample_rate_; }
  int channels() const { return channels_; }
  int64_t duration_us() const { return duration_us_; }

  // Positions the decoder so the next Read returns audio from exactly
  // [position_us] (to the frame).
  bool SeekExact(int64_t position_us, std::string* error);

  // Appends up to [max_frames] interleaved frames to [out]. Returns the
  // number of frames appended; 0 with no error means end of file.
  size_t Read(std::vector<float>* out, size_t max_frames, std::string* error);

 private:
  bool ReadSampleInto(std::vector<float>* buf, int64_t* time_100ns, bool* eof, std::string* error);

  Microsoft::WRL::ComPtr<IMFSourceReader> reader_;
  int sample_rate_ = 0;
  int channels_ = 0;
  int64_t duration_us_ = 0;
  std::vector<float> pending_;
  size_t pending_offset_ = 0;
  bool eof_ = false;
};

// Starts COM (multithreaded) and Media Foundation for the current thread's
// lifetime of this object.
class MfScope {
 public:
  MfScope();
  ~MfScope();
  bool ok() const { return ok_; }

 private:
  bool ok_ = false;
  bool com_ = false;
};

// Duration and tags of a local file: {durationMs, title, artist, album,
// mimeType} (missing values omitted).
std::map<std::string, std::string> ProbeFile(const std::string& path, int64_t* duration_ms, std::string* error);

// Decodes [path] into a 16-bit PCM WAV at [out_path] (exact seeking for any
// format). Fills sample rate, channels and duration.
bool DecodeToWav(const std::string& path, const std::string& out_path, int* sample_rate, int* channels,
                 int64_t* duration_us, std::string* error);

}  // namespace syncsphere_audio

#endif  // SYNCSPHERE_AUDIO_MEDIA_DECODER_H_
