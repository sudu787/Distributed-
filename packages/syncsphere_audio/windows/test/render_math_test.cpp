// Unit tests for render_math.h (portable; built with g++ in CI and locally):
//   g++ -std=c++17 -O1 -I.. render_math_test.cpp -o render_math_test && ./render_math_test
#include "../render_math.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

using namespace syncsphere_audio;

static int failures = 0;
#define CHECK(cond)                                                    \
  do {                                                                 \
    if (!(cond)) {                                                     \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);      \
      failures++;                                                      \
    }                                                                  \
  } while (0)
#define NEAR(a, b, eps) CHECK(std::fabs((a) - (b)) <= (eps))

static void TestRoles() {
  const float lr[2] = {0.2f, 0.8f};
  float out[2];
  MixFrame(lr, 2, MixMatrix("left", 2), out);
  NEAR(out[0], 0.2f, 1e-6);
  NEAR(out[1], 0.2f, 1e-6);
  MixFrame(lr, 2, MixMatrix("right", 2), out);
  NEAR(out[0], 0.8f, 1e-6);
  MixFrame(lr, 2, MixMatrix("stereo", 2), out);
  NEAR(out[0], 0.2f, 1e-6);
  NEAR(out[1], 0.8f, 1e-6);
  const float same[2] = {0.5f, 0.5f};
  MixFrame(same, 2, MixMatrix("surroundLeft", 2), out);
  NEAR(out[0], 0.0f, 1e-6);  // centred content is not in the surrounds
  const float five[6] = {0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f};
  MixFrame(five, 6, MixMatrix("surroundRight", 6), out);
  NEAR(out[1], 0.9f * 0.6f, 1e-6);
  const float mono[1] = {0.7f};
  MixFrame(mono, 1, MixMatrix("left", 1), out);
  NEAR(out[0], 0.7f, 1e-6);
  NEAR(out[1], 0.7f, 1e-6);
}

static void TestResamplerUnityAndRate() {
  // A ramp source: x[n] = n / 1000.
  int n = 0;
  auto ramp = [&n](float* f) {
    if (n >= 2000) return false;
    f[0] = f[1] = n / 1000.0f;
    n++;
    return true;
  };
  StereoResampler r;
  std::vector<float> out(200 * 2);
  r.Render(ramp, 1.0, out.data(), 200);
  for (int i = 0; i < 200; i++) NEAR(out[i * 2], i / 1000.0f, 1e-6);  // step 1 = passthrough
  NEAR(r.SourcePosition(), 200.0, 1e-9);
  // Faster: step 1.01 advances 1.01 source frames per output frame; a ramp
  // interpolates exactly.
  r.Render(ramp, 1.01, out.data(), 100);
  NEAR(out[0], 0.200f, 1e-5);
  NEAR(out[99 * 2], (200 + 99 * 1.01) / 1000.0, 1e-5);
  NEAR(r.SourcePosition(), 200 + 100 * 1.01, 1e-6);
}

static void TestResamplerEnd() {
  int n = 0;
  auto shortSrc = [&n](float* f) {
    if (n >= 10) return false;
    f[0] = f[1] = 1.0f;
    n++;
    return true;
  };
  StereoResampler r;
  std::vector<float> out(40 * 2);
  const size_t audible = r.Render(shortSrc, 1.0, out.data(), 40);
  CHECK(audible >= 8 && audible <= 10);
  CHECK(r.ended());
  NEAR(out[39 * 2], 0.0f, 1e-9);
}

static void TestSineQuality() {
  // 44.1 kHz 1 kHz sine resampled to 48 kHz: compare with the analytic sine.
  const double sr = 44100, dr = 48000, f = 1000;
  int n = 0;
  auto sine = [&](float* fr) {
    fr[0] = fr[1] = static_cast<float>(std::sin(2 * M_PI * f * n / sr));
    n++;
    return true;
  };
  StereoResampler r;
  std::vector<float> out(4800 * 2);
  r.Render(sine, sr / dr, out.data(), 4800);
  double err = 0;
  for (int i = 100; i < 4800; i++) {
    const double want = std::sin(2 * M_PI * f * i / dr);
    err = std::max(err, std::fabs(out[i * 2] - want));
  }
  CHECK(err < 2e-3);  // better than -54 dB at 1 kHz
}

static void TestClockMath() {
  CHECK(CounterToNanos(10000000LL * 3600 * 24 * 30, 10000000LL) == 1000000000LL * 3600 * 24 * 30);
  CHECK(CounterToNanos(15, 10) == 1500000000LL);
  CHECK(FrameAt(1000000000LL + 500000000LL, 1000000000LL, 48000, 48000) == 48000 + 24000);
  CHECK(NanosAt(48000 + 24000, 1000000000LL, 48000, 48000) == 1500000000LL);
  NEAR(TrackPositionUs(1000, 1000, 44100, 44100, 1.0, 5000000), 6000000.0, 1e-6);
  NEAR(TrackPositionUs(1480, 1000, 44100, 44100, 44100.0 / 48000, 0), 1e6 + 10000.0, 1.0);
}

static void TestUris() {
  CHECK(FileUriToPath("file:///C:/Music/My%20Song.mp3") == "C:\\Music\\My Song.mp3");
  CHECK(FileUriToPath("file:///D:/a/b%C3%A9.flac") == "D:\\a\\b\xC3\xA9.flac");
  CHECK(FileUriToPath("C:\\x.mp3") == "C:\\x.mp3");
  CHECK(FileUriToPath("file://localhost/C:/x.wav") == "C:\\x.wav");
}

int main() {
  TestRoles();
  TestResamplerUnityAndRate();
  TestResamplerEnd();
  TestSineQuality();
  TestClockMath();
  TestUris();
  if (failures == 0) std::printf("render_math: all tests passed\n");
  return failures == 0 ? 0 : 1;
}
