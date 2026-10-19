# Surround sound with phones: research and design

Written October 2026. It covers what physics and perception allow when each phone is one loudspeaker, what SyncSphere
does, and what comes next. Simulated numbers are labelled. Nothing here has been measured on real phones yet.

## 1. What the ear needs (perception limits)

- **Below ~1 ms of arrival difference** between two speakers, the ear fuses them into one *phantom* source somewhere
  between them (summing localization). Stereo panning depends on this.
- **From ~1 ms up to the echo threshold** (≈2 ms for clicks, up to ≈40 ms for speech), the sound seems to come from
  the *earlier* speaker (law of the first wavefront / precedence effect). Matrix surround decoders exploit this on
  purpose: they delay the surround channels by **15–20 ms**, so the front stays the anchor and the rear speakers
  only add room sound (Haas effect).
- **Beyond the echo threshold** it is heard as an echo.

What that means for phones synced over Wi-Fi: SyncSphere's alignment is millisecond-level, not sub-millisecond.
- Simulated steady-state spread p50 is ≈4–8 ms.
- After "Calibrate to this spot", the simulated median at the listener is 4.6 ms.

So:
- **Distinct channels per phone work well:** left, right, center and surrounds each play different content.
- **Panning a sound *between* two phones (phantom images) is not reliable.** It needs sub-ms alignment at the
  listener.
- **Rear channels are tolerant.** They are meant to be 15–20 ms late anyway, so a few ms of sync error does not
  matter.
- **Front left/right/center benefit most from calibration at the listening spot.**

## 2. Where to put the phones (ITU-R BS.775 5.1)

| Position | Angle from straight ahead |
|---|---|
| Center (C) | 0° |
| Front left / right (L, R) | ±30° (22.5° in cinemas) |
| Surround left / right (SL, SR) | ±110° (100–120°), beside or slightly behind |
| 7.1 rear pair (Dolby) | ±135–150° |

Keep the phones at roughly equal distance from the seat. Calibration compensates the rest (timing now, levels later).

## 3. Content: upmixing stereo

Almost all music is stereo, so 5 phones need an *upmix*:

| Method | How | Quality | Cost |
|---|---|---|---|
| **Passive matrix** (implemented) | C = ½(L+R); surround = 0.707·(L−R) at −3 dB, delayed 15 ms; front L/R unchanged | Voices and centred instruments stay in front; reverb and wide stereo go to the rear. No steering, so some leakage | Tiny: a 2×2 matrix |
| Steered matrix (Dolby Pro Logic II, DTS Neo:6 style) | Tracks the dominant direction and adapts the matrix gains | Better separation | Moderate DSP; patents/branding to respect |
| Ambience extraction (STFT: PCA, inter-channel coherence, Avendano–Jot) | Splits correlated "direct" from uncorrelated "ambience" per frequency band | Best for music | FFT per block on every phone; more battery |

**Real 5.1 files** (FLAC, AAC, Opus 5.1, and E-AC-3/AC-3 where the phone has a decoder) skip the upmix: every phone
plays its own channel from the file. Front phones also take some of the center and LFE, so nothing is lost when there
is no center phone.

## 4. Phone loudspeakers

Phone speakers roll off below roughly 200–400 Hz. An informal measurement found Android phones' response starting to
rise around 220 Hz, and one iPhone around 400 Hz. So there is **no subwoofer/LFE role on a phone**. Bass stays in the
front phones; a phone driving a Bluetooth speaker can act as the "big" front speaker (its extra latency is handled by
calibration).

## 5. What SyncSphere does now

- **Roles:** Stereo, Left, Right, Mono, **Center**, **Surround left**, **Surround right**.
  - Set them on the Speakers tab (Surround button), or per phone in its sheet.
  - The speaker map draws each phone at its ITU angle around "You".
- **Compatibility:** surround roles are accepted only when every connected phone runs a version that understands them
  (`caps.sur`), so older apps never receive values they cannot parse.
- **Mixing** (Android, `ChannelRoleProcessor`): stereo and 5.1 matrices as above, applied to 16-bit or float PCM.
  Calibration clicks always play unmixed, because a difference matrix would cancel a mono click.
- **Timing:** rear phones play `kSurroundDelayUs` = 15 ms later, as an offset in the engine.
  - In the simulation the shift lands at 7–23 ms, because every phone may sit anywhere inside the drift controller's
    ±8 ms band. That is still inside the Haas window.
  - Calibration clicks are played without the role delay, so calibration does not cancel it.
- **Identify:** tap a phone on the map to make it flash its role and vibrate.
- **Every speaker of a phone plays that phone's channel.** A phone with two loudspeakers set to Right plays the right
  channel from both. Most songs carry the voice, bass and drums in *both* channels, so a left/right pair playing a song
  can sound almost the same from both phones. **Test sound** (on the speaker map) plays three low beeps on the left
  channel only, three high beeps on the right only, then a tone in both channels in phase (left, right and center
  phones) and one in anti-phase (only the surround phones). The file is generated identically on every phone.
- **Role changes take effect mid-song.** The role is fixed in each native player, so a change starts a fresh segment.
  If a change arrived while the song was still starting, it used to be lost until the next song: one phone stayed on
  full stereo next to the other's single channel, which sounds like "the right channel on both phones". The engine
  now checks the playing segment's role on every drift tick and switches if it is wrong (regression test in
  `simulation_test.dart`).

## 6. Surround calibration with every phone's microphone (implemented)

"Calibrate to this spot" uses one microphone (the listener's phone) and fixes *timing* at the seat. **Measure
automatically** (in the Surround sheet) has every phone with a microphone record the same click sequence. That gives
the room layout without placing anything by hand.

- **Consent:** another phone's microphone is used only if its owner turned on **Help measure the room** in Settings
  (off by default). Otherwise that phone declines at once, records nothing, and shows who asked, with a button to allow
  it next time. Recordings never leave a phone; only click arrival times and levels are sent.
- **Distances without trusting clocks:** two-way sensing (BeepBeep; Peng et al., SenSys 2007, ~1–2 cm on phones).
  - With A_x(y) = arrival of y's click in phone x's own recording:
    d_xy = c/2 · [(A_x(y) − A_x(x)) − (A_y(y) − A_y(x))] + (d_xx + d_yy)/2, with d_xx = 8 cm (speaker to own mic).
  - Every term is a difference inside one recording, so clock offsets and output-latency jitter cancel.
  - Median over the 3 rounds.
- **Layout:** classical multidimensional scaling of the distance matrix (Birchfield and Subramanya), computed by the
  coordinator for the largest set of phones that heard each other. It needs 3 phones including the seat phone.
  - On the seat phone the user taps the phone(s) *in front*: the center phone, or the front-left and front-right
    phones, in which case forward is midway between them. Then they tap a phone *on the left* (mirror).
  - MDS is sensitive to outliers. The fit residual is shown, with a warning above 25 cm.
- **Automatic roles** from each phone's angle: 2 phones → L/R. Otherwise the phone nearest straight ahead (within
  ±20°) is center, phones within ±75° are front L/R, and phones further round are SL/SR.
- **Level matching** from the click levels at the seat. Every phone is brought down to the quietest front phone, and
  the surrounds a further 3 dB, using its device volume. The seat phone itself is left out.
- **Timing** at the seat comes from the same run (the listener's recording, exactly as "Calibrate to this spot").

**Simulated result** (`surround-calibration-n6`, seed 42: listener + C, L, R at 2 m, SL, SR at 1.8 m, two phones on
uncalibrated Bluetooth):

| metric | value |
|---|---|
| pairwise distance error | median 0.8 cm, max 2.0 cm |
| angle error after orienting | median 0.3°, max 0.5° |
| suggested roles | C, L, R, SL, SR, all correct |
| spread at the listener afterwards | median 7.4 ms, p95 14.2 ms (without any calibration: about 180 ms on seeds 1 and 2) |

Over three seeds on good and typical Wi-Fi, the worst distance error was 7.4 cm and the worst angle error 1.4°. On
seeds 1 and 2 the timing at the seat matched "Calibrate to this spot" in the same room to within 0.1 ms (median). The
simulation has **no reverberation, multipath or speaker directivity**, and onsets are found in clean recordings.
Real rooms will be worse, so the residual warning and manual assignment stay. These are SIMULATED numbers, not
hardware measurements.

- **Arbitrary layouts:** VBAP (vector base amplitude panning, Pulkki 1997) can map virtual channels onto real phone
  angles. Because it relies on phantom images, it needs the sub-ms alignment discussed above, so it stays future
  work.

## 7. Real-phone test procedure

1. Five phones on one Wi-Fi network, same volume, placed around a chair (C, L, R, SL, SR). Turn on "Help measure the
   room" on each.
2. Sit in the chair with a sixth phone, open Speakers → Surround → **Measure**. Tap the front phone and a left phone,
   check the map matches the room, then **Use this layout**. (Or assign positions by hand and run "Calibrate to this
   spot".)
3. Play **Test sound**: the low beeps should come only from the left phones, the high beeps only from the right, the
   third tone from the front three and the last tone only from behind.
4. Play a stereo track with a centred voice and lots of reverb (live recordings work well). Expected: the voice stays
   in front, and reverb and audience come from around you.
5. Play a 5.1 test file (channel-ID announcements) and confirm each phone speaks its own channel.
6. Optionally record at the seat with a measurement microphone and run `tools/onset_skew.py` on a click track to
   measure front alignment and the rear delay.

## Sources

- Summing localization and precedence thresholds: arXiv 2307.00084 (The Human Auditory System and Audio); arXiv
  1907.11425 (Localization uncertainty in time-amplitude stereophonic reproduction); Wallis and Lee 2015 (Huddersfield
  eprint 25888); PMC4310855.
- ITU-R BS.775 positions as summarized by Apple Logic Pro docs, Auralex and theatercalc.com.
- Upmixing: Chalmers thesis "Stereo-to-Five Channels Upmix Methods, Implementation and Comparative Study"; Avendano and
  Jot (US 8346565); passive vs. steered decoders (US 8588427); earticle A148266.
- Surround delay and Haas window: US 5386473; NTi Audio "Haas effect".
- VBAP: V. Pulkki, "Virtual Sound Source Positioning Using Vector Base Amplitude Panning", JAES 45(6), 1997; Csound
  vbapg.
- Phone loudspeaker response: Audiokinetic blog "Loudness and frequency response on popular smart phones"; US 9118992.
- Acoustic ranging: C. Peng et al., "BeepBeep: A High Accuracy Acoustic Ranging System using COTS Mobile Devices",
  SenSys 2007; ACM TECS 2012 version.
- MDS self-calibration: S. Birchfield and A. Subramanya, "Microphone array position calibration by basis-point
  classical multidimensional scaling", IEEE TSAP 2005; arXiv 1409.0203.
- Multi-phone playback sync: ETH Zürich semester thesis SA-2015-02 "Distributed Speaker Synchronization".
- Media3 `ChannelMixingAudioProcessor` documentation (developer.android.com).
