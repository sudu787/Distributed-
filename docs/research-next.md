# Research: what to build next

Written October 2026. It answers three questions:

1. Which distributed-systems techniques would make SyncSphere better?
2. Can Spotify or other music services play through it?
3. Does a web browser help where DRM gets in the way?

Facts about third-party services come from their public documentation and policies (see Sources) and can change.

## 1. Music services

| Approach | Technically possible? | Allowed? | Sync quality |
|---|---|---|---|
| Host plays Spotify and streams the audio to the guests | **No.** Spotify audio is Widevine-protected inside the Spotify app or player, and apps cannot capture it (DRM players opt out of Android playback capture) | **No.** The Spotify Developer Policy forbids "non-interactive webcasting", for example "an application which plays content from a single source to several simultaneous listeners" | — |
| Every phone runs its own Spotify (App Remote SDK, or the Web Playback SDK in a WebView), and SyncSphere tells each one what to play and where | Partly | Grey area, and limited. In Development Mode an app is limited to 5 users and needs the developer to have Premium; extended quota is only for organizations with about 250k monthly users. App Remote sessions drop after ~30 s without playback | Coarse. The APIs offer seek but no scheduled start or rate control, so expect tens to hundreds of ms (unmeasured) |
| YouTube IFrame player in a WebView on each phone | Yes | The player must stay visible; no background playback | Coarse, as above. Ads play independently on each phone and break sync |
| WebView to get around DRM | **No.** Widevine decrypts inside the CDM, so the page and the app never see the audio | Circumventing it would breach anti-circumvention law and the service terms | — |
| **Open catalogs and personal servers:** Audius API (free, streaming allowed with artist credit), Jamendo (Creative Commons), Internet Archive, Navidrome/Subsonic, Jellyfin, podcast RSS | **Yes**: plain HTTP files | Yes, within each catalog's terms | **The same as local files.** Every phone fetches the same bytes, verified by SHA-256, and plays them on the shared timeline |

**Decision:** SyncSphere adds *open music sources*: Audius search and "add from a link". When a song has a source URL, every phone downloads it from the source itself, so the catalog streams to each listener. The host and peers are only a fallback. Spotify and YouTube integration is not planned. Spotify Jam already offers a shared queue on one speaker.

## 2. Distributed-systems techniques

Ranked by value for effort in this codebase:

| # | Technique | What it fixes here | Status |
|---|---|---|---|
| 1 | **φ accrual failure detector** (Hayashibara et al. 2004; as used in Akka and Cassandra) plus an adaptive stall margin | Fixed 3 s / 8 s timeouts were slow on good Wi-Fi and blind to the link's jitter | **Implemented**, see below |
| 2 | **Peer-to-peer chunk swarm** (BitTorrent-style, content-addressed chunks with a chunk root) | The host's Wi-Fi uplink limits song start-up with 5–10 phones, and songs are lost with the host | Next |
| 3 | **Majority lease and quorum election** (Raft-style leases with the existing epoch fencing) | A phone cut off from the others must not run a second coordinator. The isolation hold-off below is a cheap, partial version | Planned |
| 4 | **Better time sync:** Kalman/least-squares skew estimation; Reference Broadcast Synchronization (receivers compare arrival times of the same UDP broadcast, removing sender jitter); Marzullo's intersection over several time sources | Tighter clock uncertainty, especially after a host change | Research, simulation first |
| 5 | **CRDT queue** (RGA sequence plus last-writer-wins registers) | Queue edits during a failover or split, merged afterwards | Planned |
| 6 | **Hybrid Logical Clocks** in event logs | One causally ordered timeline across all phones' diagnostics | Small |
| 7 | **Live PCM streaming** (RTP/RTCP-style timestamps, jitter buffer, Opus with in-band FEC) | Live sources (microphone, line-in, apps that allow capture) | Large |
| 8 | **Predictive prefetch and anti-entropy** (Bloom-filter "what I have" summaries) | Next songs ready before they are needed | Small |

### What was implemented: failure detection

- **φ accrual (`coordinator/failure_detector.dart`).**
  - Each link learns the distribution of heartbeat inter-arrival times (window of 300) and computes φ = −log₁₀ P(a heartbeat this late).
  - A link is *suspect* at φ ≥ 8 and *failed* at φ ≥ 12.
  - Silence bounds apply: 2 s before suspect, 4 s to 16 s before failed.
  - Any traffic proves liveness, but only heartbeats are learned, because clock-probe bursts would make a link look faster than it is.
- **Adaptive stall margin.** Phone Wi-Fi is regular except for rare multi-second stalls (roaming, deep power save), which a normal-distribution model underestimates. A link is therefore never declared failed before 1.25 × the longest gap it survived within the window.
- **Silence gate for failover.** When the link died by *silence* rather than a closed connection, promoting a successor still requires 8 s without hearing from the coordinator. Faster detection starts reconnect attempts sooner, but does not turn a 4 s Wi-Fi blip into a host switch. A closed connection without `bye` (the host app died) keeps the 2 s path.
- **Isolation hold-off.**
  - A phone that is not first in the succession order, and reaches none of the successors ahead of it, waits 20 s longer and goes round again (coordinator first) before promoting itself.
  - Before this, a guest cut off for ~10–20 s became a second coordinator. In the app, the higher epoch then wins split-brain resolution, so the whole room moved to the phone that dropped out.
  - The hold-off also stops two successors promoting at once.

**Simulated results** (`dart run bin/benchmark.dart --only detector-`, seed 42, 4 phones):
- 10 min of playback, then a guest cut off for 10 s at 9:20, then the host app killed at 10:20.
- `wifi-flaky` is `wifi-typical` plus a 2–5 s stall about every 40 s per phone.
- These are SIMULATED numbers, not hardware measurements.

| detector | network | stalls | member links closed | guest cut off → declared failed | host killed → successor | host changes before the kill |
|---|---|---|---|---|---|---|
| fixed 3 s / 8 s | wifi-good | 0 | 1 (the real cut-off) | 8.2 s | 2.0 s | 0 |
| φ accrual | wifi-good | 0 | 1 | **4.2 s** | 2.0 s | 0 |
| fixed 3 s / 8 s | wifi-flaky | 42 | 1 | 8.2 s | 2.0 s | 0 |
| φ accrual | wifi-flaky | 48 | 2 (1 false alarm) | **5.2 s** | 2.0 s | 0 |

How to read it:
- φ halves the time to detect a dead guest on a steady link. A dead guest no longer holds up the readiness barrier and the room view as long.
- On stall-prone Wi-Fi φ adapts (5.2 s), at the cost of one false alarm in 10 minutes. A false alarm only makes that phone reconnect; it never switches the host, because of the silence gate.
- "Host killed" closes the connection, so both detectors take the 2 s path.

## Sources

- Spotify Developer Policy (non-interactive webcasting, synchronization): https://developer.spotify.com/policy/
- Spotify Web API Development Mode changes, February 2026: https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide
- Spotify developer access update, February 2026: https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security
- Spotify Web API changelog, July 2026: https://developer.spotify.com/documentation/web-api/references/changes/july-2026
- Spotify extended-access criteria: https://developer.spotify.com/blog/2025-04-15-updating-the-criteria-for-web-api-extended-access
- Spotify Android SDK (App Remote): https://developer.spotify.com/documentation/android
- App Remote 30 s idle disconnect (Spotify staff reply): https://community.spotify.com/t5/Spotify-for-Developers/iOS-amp-Android-Remote-SDK-loses-connection-after-paused-for-30s/td-p/7077461
- Spotify Web Playback SDK: https://developer.spotify.com/documentation/web-playback-sdk
- Web Playback SDK on Android, EME errors: https://community.spotify.com/t5/Spotify-for-Developers/The-Web-Playback-SDK-seems-to-no-longer-work-on-Android/td-p/6640921
- Widevine DRM overview: https://developers.google.com/widevine/drm/overview
- Android audio playback capture and opt-out: https://developer.android.com/media/platform/av-capture
- YouTube API Services Developer Policies: https://developers.google.com/youtube/terms/developer-policies
- YouTube required minimum functionality: https://developers.google.com/youtube/terms/required-minimum-functionality
- Audius REST API: https://docs.audius.org/developers/guides/rest-api
- Audius SDK and API plans: https://docs.audius.org/developers/sdk/overview
- N. Hayashibara, X. Défago, R. Yared, T. Katayama: "The φ Accrual Failure Detector", SRDS 2004.
- W. Chen, S. Toueg, M. K. Aguilera: "On the Quality of Service of Failure Detectors", IEEE TC 2002.
- J. Elson, L. Girod, D. Estrin: "Fine-Grained Network Time Synchronization using Reference Broadcasts", OSDI 2002.
