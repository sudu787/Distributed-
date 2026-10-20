#include "media_decoder.h"

#include <mfapi.h>
#include <mferror.h>
#include <propvarutil.h>
#include <shobjidl.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>

using Microsoft::WRL::ComPtr;

namespace syncsphere_audio {

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
  return w;
}

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return std::string();
  const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
  std::string s(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), &s[0], n, nullptr, nullptr);
  return s;
}

std::string HrMessage(const char* what, HRESULT hr) {
  char buf[96];
  std::snprintf(buf, sizeof(buf), "%s (0x%08lX)", what, static_cast<unsigned long>(hr));
  return buf;
}

MfScope::MfScope() {
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  com_ = SUCCEEDED(co);  // S_FALSE (already initialised) also needs CoUninitialize
  ok_ = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE));
}

MfScope::~MfScope() {
  if (ok_) MFShutdown();
  if (com_) CoUninitialize();
}

bool MediaDecoder::Open(const std::string& path, std::string* error) {
  reader_.Reset();
  pending_.clear();
  pending_offset_ = 0;
  eof_ = false;
  const std::wstring wpath = Utf8ToWide(path);
  HRESULT hr = MFCreateSourceReaderFromURL(wpath.c_str(), nullptr, &reader_);
  if (FAILED(hr)) {
    *error = HrMessage("cannot open the file", hr);
    return false;
  }
  const DWORD audio = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
  reader_->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  hr = reader_->SetStreamSelection(audio, TRUE);
  if (FAILED(hr)) {
    *error = HrMessage("the file has no audio", hr);
    return false;
  }
  ComPtr<IMFMediaType> want;
  MFCreateMediaType(&want);
  want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  want->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
  hr = reader_->SetCurrentMediaType(audio, nullptr, want.Get());
  if (FAILED(hr)) {
    *error = HrMessage("no decoder for this audio format", hr);
    return false;
  }
  ComPtr<IMFMediaType> got;
  hr = reader_->GetCurrentMediaType(audio, &got);
  if (FAILED(hr)) {
    *error = HrMessage("cannot read the audio format", hr);
    return false;
  }
  UINT32 rate = 0, ch = 0;
  got->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
  got->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &ch);
  if (rate == 0 || ch == 0 || ch > 8) {
    *error = "unsupported audio layout";
    return false;
  }
  sample_rate_ = static_cast<int>(rate);
  channels_ = static_cast<int>(ch);
  PROPVARIANT var;
  PropVariantInit(&var);
  if (SUCCEEDED(reader_->GetPresentationAttribute(static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
                                                  &var))) {
    duration_us_ = static_cast<int64_t>(var.uhVal.QuadPart / 10);
  }
  PropVariantClear(&var);
  return true;
}

bool MediaDecoder::ReadSampleInto(std::vector<float>* buf, int64_t* time_100ns, bool* eof, std::string* error) {
  *eof = false;
  *time_100ns = -1;
  buf->clear();
  while (true) {
    DWORD stream = 0, flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    const HRESULT hr = reader_->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, &stream,
                                           &flags, &ts, &sample);
    if (FAILED(hr)) {
      *error = HrMessage("decoding failed", hr);
      return false;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      *eof = true;
      return true;
    }
    if (!sample) continue;  // stream tick / gap
    ComPtr<IMFMediaBuffer> mbuf;
    if (FAILED(sample->ConvertToContiguousBuffer(&mbuf))) continue;
    BYTE* data = nullptr;
    DWORD len = 0;
    if (FAILED(mbuf->Lock(&data, nullptr, &len))) continue;
    const size_t floats = len / sizeof(float);
    buf->assign(reinterpret_cast<const float*>(data), reinterpret_cast<const float*>(data) + floats);
    mbuf->Unlock();
    LONGLONG st = 0;
    *time_100ns = SUCCEEDED(sample->GetSampleTime(&st)) ? st : ts;
    return true;
  }
}

bool MediaDecoder::SeekExact(int64_t position_us, std::string* error) {
  pending_.clear();
  pending_offset_ = 0;
  eof_ = false;
  // Land a little before the target: decoders resume on frame boundaries.
  const int64_t coarse_us = std::max<int64_t>(0, position_us - 500000);
  PROPVARIANT var;
  InitPropVariantFromInt64(coarse_us * 10, &var);
  const HRESULT hr = reader_->SetCurrentPosition(GUID_NULL, var);
  PropVariantClear(&var);
  if (FAILED(hr)) {
    *error = HrMessage("seek failed", hr);
    return false;
  }
  const int64_t target_frame = position_us * sample_rate_ / 1000000;
  int64_t next_frame = -1;  // frame index of the next decoded frame, once known
  std::vector<float> buf;
  while (true) {
    int64_t t = -1;
    bool eof = false;
    if (!ReadSampleInto(&buf, &t, &eof, error)) return false;
    if (eof) {
      eof_ = true;
      return true;  // seeking past the end: nothing left to play
    }
    const int64_t frames = static_cast<int64_t>(buf.size()) / channels_;
    if (t >= 0) next_frame = (t * sample_rate_ + 5000000) / 10000000;
    if (next_frame < 0) next_frame = coarse_us * sample_rate_ / 1000000;
    if (next_frame + frames <= target_frame) {
      next_frame += frames;
      continue;
    }
    const int64_t skip = std::max<int64_t>(0, target_frame - next_frame);
    pending_.assign(buf.begin() + skip * channels_, buf.end());
    pending_offset_ = 0;
    return true;
  }
}

size_t MediaDecoder::Read(std::vector<float>* out, size_t max_frames, std::string* error) {
  size_t got = 0;
  while (got < max_frames) {
    if (pending_offset_ >= pending_.size()) {
      if (eof_) break;
      int64_t t = -1;
      bool eof = false;
      if (!ReadSampleInto(&pending_, &t, &eof, error)) return got;
      pending_offset_ = 0;
      if (eof) {
        eof_ = true;
        pending_.clear();
        break;
      }
      continue;
    }
    const size_t avail = (pending_.size() - pending_offset_) / channels_;
    const size_t take = std::min(avail, max_frames - got);
    out->insert(out->end(), pending_.begin() + pending_offset_, pending_.begin() + pending_offset_ + take * channels_);
    pending_offset_ += take * channels_;
    got += take;
  }
  return got;
}

std::map<std::string, std::string> ProbeFile(const std::string& path, int64_t* duration_ms, std::string* error) {
  std::map<std::string, std::string> tags;
  *duration_ms = -1;
  MediaDecoder d;
  if (d.Open(path, error)) *duration_ms = d.duration_us() / 1000;
  ComPtr<IPropertyStore> store;
  const std::wstring wpath = Utf8ToWide(path);
  if (SUCCEEDED(SHGetPropertyStoreFromParsingName(wpath.c_str(), nullptr, GPS_DEFAULT, IID_PPV_ARGS(&store)))) {
    // PKEY_Title, PKEY_Music_Artist, PKEY_Music_AlbumTitle (propkey.h),
    // spelled out so no INITGUID translation unit is needed.
    static const PROPERTYKEY kTitle = {{0xF29F85E0, 0x4FF9, 0x1068, {0xAB, 0x91, 0x08, 0x00, 0x2B, 0x27, 0xB3, 0xD9}}, 2};
    static const PROPERTYKEY kArtist = {{0x56A3372E, 0xCE9C, 0x11D2, {0x9F, 0x0E, 0x00, 0x60, 0x97, 0xC6, 0x86, 0xF6}}, 2};
    static const PROPERTYKEY kAlbum = {{0x56A3372E, 0xCE9C, 0x11D2, {0x9F, 0x0E, 0x00, 0x60, 0x97, 0xC6, 0x86, 0xF6}}, 4};
    const struct {
      const PROPERTYKEY* key;
      const char* name;
    } keys[] = {{&kTitle, "title"}, {&kArtist, "artist"}, {&kAlbum, "album"}};
    for (const auto& k : keys) {
      PROPVARIANT v;
      PropVariantInit(&v);
      if (SUCCEEDED(store->GetValue(*k.key, &v)) && v.vt != VT_EMPTY) {
        PWSTR text = nullptr;
        if (SUCCEEDED(PropVariantToStringAlloc(v, &text)) && text != nullptr) {
          std::string s = WideToUtf8(text);
          if (!s.empty()) tags[k.name] = s;
          CoTaskMemFree(text);
        }
      }
      PropVariantClear(&v);
    }
  }
  return tags;
}

namespace {
void PutLe32(std::ofstream& f, uint32_t v) {
  const char b[4] = {static_cast<char>(v), static_cast<char>(v >> 8), static_cast<char>(v >> 16),
                     static_cast<char>(v >> 24)};
  f.write(b, 4);
}
void PutLe16(std::ofstream& f, uint16_t v) {
  const char b[2] = {static_cast<char>(v), static_cast<char>(v >> 8)};
  f.write(b, 2);
}
}  // namespace

bool DecodeToWav(const std::string& path, const std::string& out_path, int* sample_rate, int* channels,
                 int64_t* duration_us, std::string* error) {
  MediaDecoder d;
  if (!d.Open(path, error)) return false;
  const std::string part = out_path + ".part";
  std::ofstream f(Utf8ToWide(part).c_str(), std::ios::binary | std::ios::trunc);
  if (!f) {
    *error = "cannot write the decoded copy";
    return false;
  }
  const uint16_t ch = static_cast<uint16_t>(d.channels());
  const uint32_t rate = static_cast<uint32_t>(d.sample_rate());
  f.write("RIFF", 4);
  PutLe32(f, 0);
  f.write("WAVEfmt ", 8);
  PutLe32(f, 16);
  PutLe16(f, 1);
  PutLe16(f, ch);
  PutLe32(f, rate);
  PutLe32(f, rate * ch * 2);
  PutLe16(f, static_cast<uint16_t>(ch * 2));
  PutLe16(f, 16);
  f.write("data", 4);
  PutLe32(f, 0);
  uint64_t frames = 0;
  std::vector<float> buf;
  std::vector<int16_t> pcm;
  while (true) {
    buf.clear();
    const size_t n = d.Read(&buf, 16384, error);
    if (n == 0) {
      if (!error->empty()) {
        f.close();
        DeleteFileW(Utf8ToWide(part).c_str());
        return false;
      }
      break;
    }
    pcm.resize(buf.size());
    for (size_t i = 0; i < buf.size(); i++) {
      const float v = std::max(-1.0f, std::min(1.0f, buf[i]));
      pcm[i] = static_cast<int16_t>(std::lround(v * 32767.0f));
    }
    f.write(reinterpret_cast<const char*>(pcm.data()), static_cast<std::streamsize>(pcm.size() * 2));
    frames += n;
  }
  const uint64_t data_bytes = frames * ch * 2;
  if (data_bytes > 0xFFFFFFF0ull) {
    *error = "the decoded copy would be larger than 4 GB";
    f.close();
    DeleteFileW(Utf8ToWide(part).c_str());
    return false;
  }
  f.seekp(4);
  PutLe32(f, static_cast<uint32_t>(36 + data_bytes));
  f.seekp(40);
  PutLe32(f, static_cast<uint32_t>(data_bytes));
  f.close();
  const std::wstring wout = Utf8ToWide(out_path);
  if (!MoveFileExW(Utf8ToWide(part).c_str(), wout.c_str(), MOVEFILE_REPLACE_EXISTING)) {
    *error = "cannot move the decoded copy into place";
    return false;
  }
  *sample_rate = static_cast<int>(rate);
  *channels = ch;
  *duration_us = static_cast<int64_t>(frames * 1000000 / rate);
  return true;
}

}  // namespace syncsphere_audio
