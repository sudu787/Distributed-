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

## 6. Next: surround calibration with every phone's microphone

The current calibration uses one microphone (the listener's phone) and fixes *timing* at the seat. For surround, every
phone with a microphone can record during the same click sequence. That gives the room layout without any manual
placement.

- **Distances without trusting clocks:** two-way sensing (BeepBeep; Peng et al., SenSys 2007, ~1–2 cm on phones).
  - With A_x(y) = arrival of y's click in phone x's own recording:
    d_xy = c/2 · [(A_x(y) − A_x(x)) − (A_y(y) − A_y(x))] + (d_xx + d_yy)/2.
  - Every term is a difference inside one recording, so clock offsets and output-latency jitter cancel.
- **Layout:** classical multidimensional scaling on the distance matrix (Birchfield and Subramanya), with the seat
  phone at the origin.
  - The user taps the phone *in front* (rotation) and the phone *on the left* (mirror).
  - MDS is sensitive to outliers, so a residual check flags bad pairs.
- **Automatic roles** from each phone's angle (2 phones → L/R; 3 → L/R/C; 5+ → C, L/R, SL/SR).
- **Level matching** from the click levels at the seat (surrounds −3 dB).
- **Arbitrary layouts:** VBAP (vector base amplitude panning, Pulkki 1997) can map virtual channels onto real phone
  angles. Because it relies on phantom images, it needs the sub-ms alignment discussed above, so it stays optional.

## 7. Real-phone test procedure

1. Five phones on one Wi-Fi network, same volume. Put the room in Surround (C, L, R, SL, SR) around a chair.
2. Sit in the chair, run "Calibrate to this spot" from your phone.
3. Play a stereo track with a centred voice and lots of reverb (live recordings work well). Expected: the voice stays
   in front, and reverb and audience come from around you.
4. Play a 5.1 test file (channel-ID announcements) and confirm each phone speaks its own channel.
5. Optionally record at the seat with a measurement microphone and run `tools/onset_skew.py` on a click track to
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
