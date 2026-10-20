// Portable pieces of the Windows audio engine (no Windows headers), unit
// tested on any OS: channel-role mixing, the variable-rate resampler used for
// drift correction, frame/clock arithmetic, and file URI parsing.
#ifndef SYNCSPHERE_AUDIO_RENDER_MATH_H_
#define SYNCSPHERE_AUDIO_RENDER_MATH_H_

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace syncsphere_audio {

// --------------------------------------------------------------- channel roles
// Same matrices as ChannelRoleMixing.kt: coefficients are row-major
// [input * 2 + output]; every role outputs the same signal on both outputs.

inline std::vector<float> StereoCoefficients(const std::string& role) {
  const float s = 0.354f;  // 0.707 * (L - R) at -3 dB
  if (role == "left") return {1, 1, 0, 0};
  if (role == "right") return {0, 0, 1, 1};
  if (role == "mono" || role == "center") return {0.5f, 0.5f, 0.5f, 0.5f};
  if (role == "surroundLeft" || role == "surroundRight") return {s, s, -s, -s};
  return {1, 0, 0, 1};
}

// 5.1 input order: FL, FR, C, LFE, SL, SR.
inline std::vector<float> FiveOneCoefficients(const std::string& role) {
  std::vector<float> w;
  if (role == "left") w = {0.75f, 0, 0.5f, 0.35f, 0, 0};
  else if (role == "right") w = {0, 0.75f, 0.5f, 0.35f, 0, 0};
  else if (role == "center") w = {0, 0, 0.8f, 0.3f, 0, 0};
  else if (role == "surroundLeft") w = {0, 0, 0, 0, 0.9f, 0};
  else if (role == "surroundRight") w = {0, 0, 0, 0, 0, 0.9f};
  else if (role == "mono") w = {0.3f, 0.3f, 0.3f, 0.2f, 0.3f, 0.3f};
  else
    return {0.5f, 0, 0, 0.5f, 0.35f, 0.35f, 0.25f, 0.25f, 0.35f, 0, 0, 0.35f};  // 5.1 -> 2.0
  std::vector<float> out(12);
  for (int i = 0; i < 12; i++) out[i] = w[i / 2];
  return out;
}

// Matrix turning [channels] input channels into 2 outputs for [role].
inline std::vector<float> MixMatrix(const std::string& role, int channels) {
  if (channels == 1) return {1, 1};
  if (channels == 2) return StereoCoefficients(role);
  if (channels == 6) return FiveOneCoefficients(role);
  // Other layouts: use the first two channels as stereo.
  std::vector<float> m(static_cast<size_t>(channels) * 2, 0.0f);
  const auto st = StereoCoefficients(role);
  std::copy(st.begin(), st.end(), m.begin());
  return m;
}

// Mixes one interleaved input frame to stereo.
inline void MixFrame(const float* in, int channels, const std::vector<float>& m, float* out2) {
  float l = 0, r = 0;
  for (int c = 0; c < channels; c++) {
    l += in[c] * m[c * 2];
    r += in[c] * m[c * 2 + 1];
  }
  out2[0] = l;
  out2[1] = r;
}

// ------------------------------------------------------------------ resampling
// Variable-rate resampler (cubic Hermite interpolation) over a stereo frame
// source. step = sourceRate * playbackRate / deviceRate. Drift correction
// changes the rate by up to a few per cent, so a smooth interpolator is
// enough; the source is pulled one frame at a time.
class StereoResampler {
 public:
  void Reset() {
    primed_ = false;
    frac_ = 0.0;
    consumed_ = 0;
  }

  // Source frames consumed so far (after priming).
  int64_t consumed() const { return consumed_; }

  // Position inside the source in frames, including the fractional part:
  // the next output frame is interpolated at this source position (three
  // frames are buffered ahead once primed).
  double SourcePosition() const {
    if (!primed_) return 0.0;
    return std::max(0.0, static_cast<double>(consumed_) - 3.0 + frac_);
  }

  // Renders [frames] stereo frames into [out] (interleaved). [pull] fills a
  // float[2] and returns false at the end of the source (then silence).
  // Returns the number of frames that contained source audio.
  template <typename Pull>
  size_t Render(Pull&& pull, double step, float* out, size_t frames) {
    if (!primed_) {
      // History: x[-1] = x[0] (duplicate the first frame).
      if (!Next(pull, h_[1])) {
        std::fill(out, out + frames * 2, 0.0f);
        return 0;
      }
      h_[0][0] = h_[1][0];
      h_[0][1] = h_[1][1];
      if (!Next(pull, h_[2])) h_[2][0] = h_[2][1] = 0;
      if (!Next(pull, h_[3])) h_[3][0] = h_[3][1] = 0;
      primed_ = true;
    }
    size_t audible = 0;
    for (size_t i = 0; i < frames; i++) {
      if (ended_ && pending_ <= 0) {
        out[i * 2] = out[i * 2 + 1] = 0;
        continue;
      }
      const double t = frac_;
      for (int c = 0; c < 2; c++) out[i * 2 + c] = Hermite(h_[0][c], h_[1][c], h_[2][c], h_[3][c], t);
      audible++;
      frac_ += step;
      while (frac_ >= 1.0) {
        frac_ -= 1.0;
        h_[0][0] = h_[1][0]; h_[0][1] = h_[1][1];
        h_[1][0] = h_[2][0]; h_[1][1] = h_[2][1];
        h_[2][0] = h_[3][0]; h_[2][1] = h_[3][1];
        if (!Next(pull, h_[3])) {
          h_[3][0] = h_[3][1] = 0;
          if (ended_) pending_--;
        }
      }
    }
    return audible;
  }

  bool ended() const { return ended_ && pending_ <= 0; }

 private:
  template <typename Pull>
  bool Next(Pull&& pull, float* f) {
    if (ended_) return false;
    if (pull(f)) {
      consumed_++;
      return true;
    }
    ended_ = true;
    pending_ = 2;  // frames still in the interpolation window
    return false;
  }

  static float Hermite(float xm1, float x0, float x1, float x2, double t) {
    const double c0 = x0;
    const double c1 = 0.5 * (x1 - xm1);
    const double c2 = xm1 - 2.5 * x0 + 2.0 * x1 - 0.5 * x2;
    const double c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1);
    return static_cast<float>(((c3 * t + c2) * t + c1) * t + c0);
  }

  float h_[4][2] = {};
  double frac_ = 0.0;
  bool primed_ = false;
  bool ended_ = false;
  int pending_ = 0;
  int64_t consumed_ = 0;
};

// --------------------------------------------------------------- clock math

// Converts a performance-counter value to nanoseconds without overflow.
inline int64_t CounterToNanos(int64_t counter, int64_t frequency) {
  const int64_t whole = counter / frequency;
  const int64_t rest = counter % frequency;
  return whole * 1000000000LL + rest * 1000000000LL / frequency;
}

// Device frame that plays at [atNanos], given that frame [refFrame] played at
// [refNanos] on a device running at [rate] frames per second.
inline int64_t FrameAt(int64_t atNanos, int64_t refNanos, int64_t refFrame, int rate) {
  const double frames = static_cast<double>(atNanos - refNanos) * rate / 1e9;
  return refFrame + static_cast<int64_t>(std::llround(frames));
}

// Time (ns) at which device frame [frame] plays.
inline int64_t NanosAt(int64_t frame, int64_t refNanos, int64_t refFrame, int rate) {
  return refNanos + static_cast<int64_t>(std::llround(static_cast<double>(frame - refFrame) * 1e9 / rate));
}

// Track position (µs) that device frame [frame] plays, for a segment whose
// audio started at device frame [startFrame] at track position [startUs]
// and has advanced by [sourcePos] source frames (at [sourceRate]) by the
// time [renderedFrame] was rendered. Positions between rendered frames are
// extrapolated with the current playback [step].
inline double TrackPositionUs(int64_t frame, int64_t renderedFrame, double sourcePos, int sourceRate,
                              double step, int64_t startUs) {
  const double src = sourcePos + static_cast<double>(frame - renderedFrame) * step;
  return static_cast<double>(startUs) + std::max(0.0, src) * 1e6 / sourceRate;
}

// --------------------------------------------------------------- file URIs

// "file:///C:/Music/My%20Song.mp3" -> "C:\Music\My Song.mp3" (UTF-8).
// Other strings are returned unchanged.
inline std::string FileUriToPath(const std::string& uri) {
  std::string s = uri;
  if (s.rfind("file://", 0) == 0) {
    s = s.substr(7);
    if (s.rfind("localhost/", 0) == 0) s = s.substr(9);
    if (s.size() >= 3 && s[0] == '/' && std::isalpha(static_cast<unsigned char>(s[1])) && s[2] == ':') s = s.substr(1);
  } else {
    return uri;
  }
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); i++) {
    if (s[i] == '%' && i + 2 < s.size() && std::isxdigit(static_cast<unsigned char>(s[i + 1])) &&
        std::isxdigit(static_cast<unsigned char>(s[i + 2]))) {
      out.push_back(static_cast<char>(std::stoi(s.substr(i + 1, 2), nullptr, 16)));
      i += 2;
    } else {
      out.push_back(s[i] == '/' ? '\\' : s[i]);
    }
  }
  return out;
}

}  // namespace syncsphere_audio

#endif  // SYNCSPHERE_AUDIO_RENDER_MATH_H_
