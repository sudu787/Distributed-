# Threat model, security design and limitations

## Assets and trust assumptions

- **Assets:** control of playback in a room, the room's membership, the audio files offered by the host, and the
  devices' availability (battery, CPU, network).
- **Trusted:** the host device and the people the host gives the join key to.
- **Untrusted:** every other device on the same Wi-Fi or hotspot, including other guests' devices that never received
  the key. A café or office Wi-Fi is assumed hostile; a home network is assumed curious.

## Adversaries and what stops them

| Adversary | Capability | Defense | Residual risk |
|---|---|---|---|
| Curious LAN neighbor | Sees beacons, connects to the port | Joining requires the join key (HMAC challenge-response). Wrong keys are rate-limited (5/min per address). Beacons carry no secrets. | Learns that a room exists and its name |
| Prankster sending control frames | Crafts WebSocket frames | Every frame after the handshake carries an HMAC with per-session, per-direction keys. Unauthenticated control frames close the link. Role checks are enforced by the coordinator. | None known |
| Replay attacker | Records and resends frames | Per-direction sequence numbers. Fresh nonces in every session → new keys. Reflection fails because the two directions use different keys. | None known |
| Passive sniffer (WPA2-PSK insider or open network) | Reads all traffic | — | **No confidentiality**: control messages and track downloads are readable, so the music being played and the playlist are visible. A captured handshake allows *offline* guessing of the join key. PBKDF2 (60k iterations) multiplies the cost by ~6×10⁴, but an 8-character key (40 bits) is still brute-forceable with GPUs. Use a long key (26 characters = 130 bits) on hostile networks ([roadmap](roadmap.md)). |
| Rogue coordinator (spoofed beacon) | Lures clients into connecting | Mutual authentication: the coordinator must prove the key (`serverProof`, plus MAC'd frames). Clients pin the room id from discovery. | A rogue server receives the client's proof and can attempt offline guessing (same as the sniffer case) |
| Downloader without membership | Requests `/tracks/<id>` | Per-session HMAC token bound to the path and an expiry in coordinator time. Only playlist tracks the host serves are reachable. The URL contains no filesystem path. | A member can download every served playlist track, which is the feature |
| Member uploading songs | Sends files with `PUT /uploads/<id>` | Only members with control rights, method-bound HMAC token, one upload per session, 512 MiB cap, stored only if the SHA-256 matches the id (no substitution of another track), uploads written to a temporary file and moved into the track cache | A controller can fill the host's cache up to its LRU limit; the content is not inspected (any bytes with a matching hash are accepted) |
| Resource exhaustion | Floods connections, huge frames, many downloads | Max 32 pending handshakes, 5 s handshake timeout, 256 KiB frame limit (checked after receipt; WebSocket compression disabled), malformed-message budget, participant cap (16), transfer concurrency (2 per session, 8 total), 512 MiB file cap, bounded caches and logs | A determined LAN attacker can still saturate Wi-Fi airtime; no software defense exists for that |
| Malformed or hostile input | Invalid JSON, wrong types, out-of-range values, malicious config | Strict `Reader` validation with typed errors. Config values are clamped (a malicious `maxRateDelta` cannot exceed 25 %). Fuzz-style tests check that malformed input never throws anything except `ProtocolException`. | Bugs in the JSON/WebSocket stack of the Dart VM |

### Failover, handback and redirects

`handover`, `handover.ack` and `redirect` travel only on authenticated, MAC'd, replay-protected channels, and only a
coordinator can send `handover`/`redirect` (participants never accept them from anyone else). Discovery beacons are
**not** authenticated: a forged beacon with a higher epoch could make a coordinator step down and redirect its
members to an attacker's address. The members then fail the handshake there (no room key), fall back to the
succession order and promote a real member, so the impact is a short disruption, not a takeover; a fix (signing
beacons with the room key) is on the roadmap. The original host keeps its room's join key in app-private storage to
rejoin after a crash; it is deleted when the user ends or leaves the party.

### Invite QR codes and join links

`syncsphere://app/join?h=…&p=…&r=…&k=…` contains the join key, so it is exactly as sensitive as the key: anyone who
sees the QR code or gets the link can join. The QR is shown only on demand on the host, and the UI says so. Parsing is
strict (`JoinLink.tryParse`: allowed characters, length limits, port range, at most 8 hosts) because links arrive from
outside the app (camera apps, messengers). A link only fills in a join; it never skips authentication. When the app is
already in a room, opening a link does nothing but show a message.

## Why not TLS yet

TLS on a LAN needs certificate trust. A self-signed certificate would require pinning its fingerprint, transferred
out-of-band (a QR code). That fits the roadmap together with a PAKE (for example SPAKE2/CPace), which removes offline
guessing entirely and works with short typed keys. Until then, the protocol aims for **authentication and integrity**,
explicitly **not confidentiality**. The UI says to share the key only with people in the room.

## Privacy

- **Microphone (acoustic calibration):** recording happens only on the listener's phone, only for the calibration
  segment (15–30 s), after an explicit confirmation and the Android permission prompt. The recording is analyzed on
  the phone and deleted; only per-click timing numbers (`cal.res`) are sent to the coordinator.

- Device ids are random per installation, not hardware identifiers.
- No data leaves the local network and nothing is sent to any server. There is no analytics.
- Event logs stay on the device.

## Legal

SyncSphere only plays files the user imported. Hosts must only distribute audio they are authorized to share; the
"create room" dialog says so. There is no integration with commercial streaming services.

## Limitations (functional)

1. **Coordinator failover is succession, not consensus.** If the host crashes, the first eligible guest takes over
   (epoch + 1) and the others follow. Playback continues. Under a network *partition* both sides can end up with a
   coordinator, and they do not merge automatically ([roadmap.md](roadmap.md#coordinator-failover-milestone)).
   Without candidates, sessions retry for ~3–4 minutes and then report "the room may need to be recreated".
   A failover candidate learns nothing beyond what every member already has: the join key and the state.
2. **No real-device measurements yet** (see [benchmarking.md](benchmarking.md)). All quantitative claims are simulated
   or unit-tested.
3. **The Android native code has only been compiled and unit-tested in CI**, not exercised on hardware.
4. **Foreground only.** The screen is kept on in a room; background playback with a media notification is a roadmap
   item.
5. **Android only.** The core is platform-independent, but there is no iOS audio backend.
6. **Discovery** fails under AP client isolation and on networks that filter broadcasts; use manual address entry.
7. **Acoustic alignment** depends on per-device output latency the OS does not report. A calibration offset exists,
   but measuring it needs a microphone and is manual.
8. **Room size** is capped at 16 by default (configurable to 256). Simulation covers 10.
9. **Seeks are audible** on devices without rate control when drift exceeds 45 ms.
10. **Clock uncertainty is conservative.** The UI shows a bound (often ±2–3 ms), not the typical error.
