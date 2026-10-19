# SyncSphere distributed playback protocol — version 1

This is the normative description of what goes on the wire. The reference implementation is
`packages/syncsphere_core/lib/src/protocol/` (`messages.dart`, `codec.dart`, `auth.dart`) and
`model/room_state.dart`. Field names below are the exact JSON keys.

## 1. Transport and framing

- **Control channel:** WebSocket (RFC 6455) at `ws://<host>:<port>/ws`, text frames only, no permessage-deflate.
  The default port is 47800.
- **Track delivery:** HTTP/1.1 `GET /tracks/<sha256>` on the same port (§8).
- **Discovery:** UDP broadcast to port 47801 (§9).
- **Frame:** `<tag>.<json>`
  - `json` is the envelope `{"v":1,"t":"<type>","s":<seq>,"b":{...}}`.
  - `tag` is `-` for handshake frames. Otherwise it is base64url (no padding) of the first 16 bytes of
    `HMAC-SHA256(directionKey, utf8(json))`, computed over the *exact* transmitted JSON bytes, so no canonicalization
    is needed.
- `v` is the envelope major version. A receiver rejects any other value with `unsupported_version`.
- `s` is a per-direction sequence number starting at 1 and strictly increasing. A non-increasing `s` is rejected as
  `replay`. Connections are ordered, so on an authenticated channel this can only mean replay or injection.
- Limits: 256 KiB per frame, 512 characters per string unless noted, 1000 playlist entries, 256 participants per list.
  Violations raise `ProtocolException(code)` and never crash the receiver.

### Error handling rules

| Situation | Receiver action |
|---|---|
| Malformed frame during handshake | `reject{protocol_error}` and close |
| `bad_mac`, `replay`, or an unauthenticated non-handshake type on an active channel | Close the link (security event logged) |
| Malformed body on an active channel | Reply `err{code, reason}`. More than 20 in a minute closes the link. |
| Unknown message `t` | Ignore and log (forward compatibility) |
| Unknown fields | Ignore |

## 2. Handshake and authentication

```
C → S  hello      (tag "-")
S → C  challenge  (tag "-")
C → S  auth       (tag "-")
S → C  welcome    (MAC'd)      | reject (tag "-")
```

- `K = PBKDF2-HMAC-SHA256(password = normalizedJoinKey, salt = "syncsphere-v1|" + roomId, iterations = kdf, dkLen = 32)`.
  The join key is normalized as follows: uppercase, remove spaces, dashes and underscores, then map I/L→1 and O→0
  (Crockford).
- `ctx = roomId|deviceId|clientNonce|serverNonce`
- `clientProof = b64url(HMAC(K, "c|" + ctx))`, `serverProof = b64url(HMAC(K, "s|" + ctx))`
- `master = HMAC(K, "k|" + ctx)`; the derived keys are `c2s = HMAC(master,"c2s")`, `s2c = HMAC(master,"s2c")` and
  `xfer = HMAC(master,"xfer")`.
- The client proves first. An unauthenticated client therefore never receives anything that would let it test
  join-key guesses offline. Failures are rate-limited per remote address (5 per minute by default, then `rate_limited`).
- The client activates `c2s`/`s2c` right after sending `auth`. Until `welcome` arrives it accepts exactly one
  unauthenticated frame type, `reject`.
- If the client's `roomId` (when given) differs from the challenge, or `serverProof` is wrong, the failure is fatal
  (`wrong_room` / `server_auth_failed`).

### hello (C→S)
| key | type | notes |
|---|---|---|
| `pmin`, `pmax` | int | Supported protocol range (currently 1..1) |
| `dev` | string | Device id, `^[A-Za-z0-9_-]{4,64}$`, persistent per installation |
| `name` | string 1–64 | Display name |
| `plat` | string ≤32 | e.g. `android` |
| `nonce` | string 16–64 | Random, base64url |
| `room` | string? | Expected room id (from discovery) |
| `caps` | object | `{rate: bool, backend: string, lan: bool, canHost: bool, fport?: int, mic?: bool, cal?: int}`. `fport` is the port this device would serve on if promoted (failover). `mic`: the device can record for acoustic calibration. `cal`: its saved output calibration offset (µs, ±2 s), adopted as the member's room value when it first joins. |

### challenge (S→C)
`proto` (chosen version), `room`, `name`, `coord` (coordinator device id), `epoch` (coordinator epoch),
`inst` (coordinator *process* instance id; when it changes, discard all clock samples), `nonce`, and `kdf`
(PBKDF2 iterations, 1–10⁷; clients refuse more than 2×10⁶).

### auth (C→S)
`proof`, plus `resume` (optional: the previous session id).

### welcome (S→C)
`session` (session id), `role` (`host|controller|listener`), `proof` (server proof), `config` (§6), and `state` (§4).

### reject (S→C)
`code` and `reason`. Codes: `unsupported_version`, `auth_failed`, `room_full`, `rate_limited`, `wrong_room`,
`handshake_timeout`, `protocol_error`, `room_closed`. The client treats `auth_failed`, `wrong_room`,
`unsupported_version` and `room_closed` as fatal and stops retrying.

## 3. Steady-state messages

| `t` | dir | body | purpose |
|---|---|---|---|
| `hb` | both | `{t}` sender's monotonic µs | Heartbeat. Any traffic counts as liveness. |
| `clk.req` | C→S | `{id, t1}` | Clock probe |
| `clk.res` | S→C | `{id, t1, t2, t3}` | `t2` is stamped before parsing, `t3` just before sending |
| `state` | S→C | `{state}` | Full authoritative snapshot (§4) |
| `ready` | C→S | `{gen, track, ok, err?, lat, rtt, unc}` | Result of preparing pending segment `gen`. `lat` = start-latency compensation (µs), `rtt` = clock RTT p95 (µs), `unc` = clock uncertainty (µs). `err` ∈ `missing_track`, `hash_mismatch`, `download_failed`, `decode_error`, `prepare_error`, `too_large`. |
| `ctl` | C→S | `{rid, act, base, posUs?, track?, val?, dev?, role?, mode?, off?, info?, to?}` | Control request (§5). `mode` ≤16 chars, `off` signed µs within ±1 000 000, `to` a playlist index. |
| `ctl.ack` | S→C | `{rid, ok, err?, ver}` | Result. `ver` = state version after applying it. |
| `rep` | C→S | `{gen, at, pos, exp, err, rate, buf, off, unc, rtt, mode, ps}` | Sync report: coordinator-domain measurement time, rendered and expected position, error = pos − exp (µs), current rate, buffered µs, clock offset and uncertainty, RTT p95, correction mode (`idle|waiting|inSync|rateCorrecting|resyncing`), player state |
| `evt` | C→S | `{kind, gen, detail?, data}` | `started` (data: `startErrorUs`, `playCallLateUs`, `latencyCompUs`), `lateJoin` (`lateUs`), `resync` (`posUs`), `stall`, `rejoined` (`recoveryUs`, `errorUs`), `error` |
| `avail` | C→S | `{tracks:[{id, a}]}` | Track availability: `unknown|available|fetching|missing|mismatch`. Partial updates allowed. |
| `cal.res` | C→S | `{id, arr: {dev: {slot: µs}}, missing?: [dev], lvl?: {dev: dBFS}, err?}` | Acoustic calibration result from the plan's listener, or from any recorder of a surround measurement (§5.2): per device, each detected click's arrival minus its scheduled time (common recorder offset included), and the median click peak level. Slots are string keys; ≤256 devices, ≤100 slots each. `err: "declined"`: the phone's owner has not allowed room measurement from other phones. |
| `diag` | S→C | `{parts:[{id, err?, unc?, off?, rtt?, mode, age?, rate, ps, be}], maxPair?}` | Aggregated diagnostics, about 1 Hz. Not versioned state. |
| `bye` | both | `{reason}` | Graceful leave (C→S removes the member) or room closed (S→C, fatal for the client) |
| `err` | S→C | `{code, reason}` | Non-fatal error report |

All positions and times are integer microseconds. Every reported timing value is a software estimate.

## 4. Room state

```json
{
  "room": "K7Q2M9", "name": "Living room", "coord": "dev-abc", "epoch": 1, "ver": 42,
  "tl": {"gen": 7, "track": "<sha256>", "status": "playing", "posUs": 63000000, "atUs": 912345678901, "rate": 1.0},
  "pending": {"gen": 8, "track": "<sha256>", "posUs": 0, "play": true},
  "playlist": [{"id": "<sha256>", "title": "…", "artist": "…", "durUs": 215000000, "size": 5123456,
                "mime": "audio/mpeg", "serves": true, "avail": 3}],
  "mvol": 0.8,
  "parts": [{"id": "dev-abc", "name": "Host", "role": "host", "conn": "connected", "vol": 1.0,
             "track": "available", "canHost": false, "cal": 0},
            {"id": "dev-def", "name": "Kitchen", "role": "controller", "conn": "connected", "vol": 1.0,
             "track": "available", "canHost": true, "ep": "192.168.1.31:47800", "ch": "left", "cal": 182000}],
  "dist": "auto",
  "rep": "all", "shuf": true,
  "cal": {"id": 3, "listener": "dev-abc", "order": ["dev-abc", "dev-def"], "leadUs": 6000000, "ivUs": 600000,
          "rounds": 3, "hz": 2000, "ms": 4}
}
```

- Tracks may carry optional `src` (http/https source URL, ≤ 1024 chars), `art` (cover URL) and `credit` (≤ 64 chars,
  e.g. "via Audius"). With `src`, every device downloads the file from the source first (no auth header, up to 5
  redirects, same size cap) and falls back to `GET /tracks/<id>` from the coordinator. The SHA-256 `id` is checked
  either way, so a changed source falls back to the host's copy.
- Tracks may carry `croot`: SHA-256 over the track's 512 KiB chunk hashes, computed by the coordinator from its own
  copy (never taken from a member). It enables phone-to-phone sharing (§8).
- Participants may carry `peer` (`host:port` of the device's peer file server, from `caps.pport` and the address the
  coordinator sees).
- `rep` (`off|all|one`, default `off`) and `shuf` (default `false`) control `next`/`previous` and auto-advance.
- `nxt` (optional) is the track that plays after the current one, in play order (it follows shuffle and repeat). It is
  absent when nothing is loaded or at the end of the playlist.
- Per participant: `ch` is the channel role (`stereo` default and omitted, `left`, `right`, `mono`, `center`,
  `surroundLeft`, `surroundRight`; rear surround roles play 15 ms later, see [surround.md](surround.md)); `cal` is the
  output calibration offset (µs) the device applies (rendered position = reported position − `cal`).
- `layout` (room level, optional): the last surround measurement (§5.2), `{id, listener, pos: {dev: [x, y]}, lvl?:
  {dev: dBFS}, res}`. Positions are metres in an arbitrary rotation and mirror image; `res` is the RMS misfit of the
  distances (m).
- `cal` (room level) is present only while an acoustic calibration runs (§5.1). Its plan may list `rec` (recording
  devices) for a surround measurement. Its click track id is
  `sha256("syncsphere-calibration-v1|<id>|<listener>")`; `trackById` resolves it to a synthetic track that every device
  generates locally.

- `ver` increases on every change. A receiver applies a snapshot only when `(epoch, ver)` is newer than what it holds.
  A higher `epoch` always wins, and a lower one is ignored.
- `tl` is the timeline: `expected(t_coord) = posUs + (t_coord − atUs) × rate` while `status = playing` and
  `t_coord ≥ atUs`; otherwise it is `posUs`. `atUs` is a coordinator monotonic time.
  - For `status = paused`, `atUs` is when the pause takes effect.
- `gen` increases on every discontinuity: start, pause, resume, seek, track change, auto-advance. Every `ready`, `rep`
  and `evt` names a generation, and anything for another generation is ignored.
- `pending` asks participants to prepare (download, decode, buffer) a segment without starting it. Each participant
  answers `ready`. The coordinator then publishes a playing `tl` with the same `gen` and a future `atUs`.

## 5. Control semantics and consistency

Only `host` and `controller` may send playback actions. A `listener` may change only its own device volume.
`setRole` is host-only, and nobody can grant `host`.

| `act` | args | effect | stale check |
|---|---|---|---|
| `play` | — | idle → prepare the first or current track; paused → prepare at the paused position; already playing → no-op | never |
| `pause` | — | Playing → paused timeline with future `atUs = now + lead`, position = expected(atUs). Preparing → cancel the start. | never (idempotent) |
| `seek` | `posUs` | Playing → prepare a new segment at `posUs`. Paused → new paused timeline at `posUs`. | `base ≥ timelineVersion` |
| `setTrack` | `track`, `posUs?` | Prepare and play the given track | `base ≥ timelineVersion` |
| `next` / `previous` | — | Neighbor track; `previous` restarts the current track if more than 3 s in | `base ≥ timelineVersion` |
| `masterVolume` | `val` 0–1 | Room volume | never |
| `deviceVolume` | `val`, `dev?` | Per-device volume (default: the sender's) | never |
| `setRole` | `dev`, `role` | Promote or demote | never |
| `setRepeat` | `mode` `off\|all\|one` | Playlist repeat | never |
| `setShuffle` | `val` (≥0.5 = on) | Shuffle order (reshuffled when turned on or when the playlist changes) | never |
| `setChannelRole` | `mode` `stereo\|left\|right\|mono\|center\|surroundLeft\|surroundRight`, `dev?` | Channel role. A device may always change its own; others need control rights. Surround roles (`center`, `surroundLeft`, `surroundRight`) are refused with `invalid` unless every connected member sent `caps.sur: true`. | never |
| `setCalibration` | `off`, `dev?` | Output calibration offset. Own device always; others need control rights. | never |
| `calibrate` | `mode?` (`surround`) | Acoustic calibration measured by the sender's microphone (§5.1). Needs `caps.mic`. With `mode: surround`, every connected phone with `caps.mic` records too (§5.2); needs at least two. | — |
| `identify` | `dev?` | That phone flashes its channel and vibrates for 3 s (state `ident: {dev, seq, until}`). Own phone always; others need control rights. | never |
| `addTrack` | `info` (track object, §4) | Appends a song. Needs control rights, and the coordinator must already have the file (uploaded with `PUT /uploads/<id>`, §8, or in its library); otherwise `invalid`. Idempotent. | never |
| `removeTrack` | `track` | Removes the song. Removing the song that is playing (or about to start) moves on to the next song in play order, paused if it was paused; with nothing left it stops (idle). If auto-advance was preparing the removed song, the current song keeps playing and the following one is prepared instead. Refused with `busy` for the song a running calibration will restore. | never |
| `moveTrack` | `track`, `to` | Moves the song to playlist index `to` (clamped). Moving a song directly after the current one while shuffling also makes it next in the shuffle order ("play next"). | never |

While a calibration runs, `play`, `pause`, `seek`, `setTrack`, `next`, `previous` and `calibrate` are refused with
`busy`.

`base` is the state version the sender's UI showed. `timelineVersion` is the version at which the timeline, the pending
segment or the playlist last changed. An action that could overwrite a newer conflicting intent (seeking within a track
that someone else has just replaced) is refused with `stale_version`; the UI refreshes and the user retries. Membership
and volume churn do not make playback commands stale. Ack error codes: `unauthorized`, `stale_version`, `invalid`,
`unknown_track`, `nothing_to_play`, `busy`, `not_connected`, `timeout` (client side).

### 5.1 Acoustic calibration

1. A device with a microphone sends `calibrate`. The coordinator remembers the current timeline, publishes the plan in
   `state.cal` (connected devices in `order`) and schedules the calibration track like any other segment (readiness
   barrier, future start).
2. Every device renders its *own* click track: silence except a 4 ms 2 kHz burst at
   `slot = round × |order| + index`, position `leadUs + slot × ivUs`. Devices click one at a time.
3. The listener records from `leadUs − 0.5 s` to the last slot `+ 0.8 s`, finds each click's onset in a window around
   its scheduled time and sends `cal.res` with raw arrivals. The recording never leaves the phone.
4. The coordinator adds each device's own software error at each click time (from its `rep` reports during the
   calibration) to the raw arrival, takes the median per device and subtracts the median across devices. The result
   is added to each member's `cal` (clamped to ±1 s). A device that is still converging therefore does not bias its
   correction.
5. The coordinator restores the previous track as paused at the position it had reached (or idle if nothing was
   loaded). If no result arrives within the track length plus readiness timeout, maximum lead and 20 s, the
   calibration is cancelled the same way, with no offsets changed.

The corrections align sound **at the listener's position**, including propagation delay (about 2.9 ms per metre) and
Bluetooth or speaker latency that software estimates cannot see. Other positions in the room are not aligned by this.

### 5.2 Surround measurement (every phone listens)

1. `calibrate` with `mode: surround`. The plan carries `rec`: the listener plus every other connected phone with
   `caps.mic`. The click sequence is the same as §5.1.
2. Each recorder that its owner allows (app setting "Help measure the room", off by default) records the whole sequence
   and sends `cal.res` with its arrivals and levels. A phone that is not allowed answers at once with `err: "declined"`
   and records nothing. Recordings never leave the phones.
3. The listener's result applies timing corrections exactly as in §5.1. The coordinator then waits for every recorder's
   answer (at most 6 s more) and computes:
   - pairwise distances by two-way ranging: `d_xy = c/2 · [(A_x(y) − A_x(x)) − (A_y(y) − A_y(x))] + d_self`, where
     `A_x(y)` is the arrival of y's click in x's recording, c = 343 m/s and `d_self` = 0.08 m (speaker to own
     microphone). Every term is a difference within one recording, so clock offsets and output latency cancel. Median
     over the rounds;
   - the largest set of phones with all pairs measured, then 2-D positions by classical multidimensional scaling.
4. With at least 3 phones including the listener, it publishes `layout`. The listener's app asks the user for the
   phone(s) in front and a phone on the left, which fixes rotation and mirror image, and then suggests roles from the
   angles and volume trims from the levels. It applies them with ordinary `setChannelRole` and `deviceVolume` requests.

## 6. Synchronization configuration (`welcome.config`)

Distributed by the coordinator so the whole room uses one policy. Hostile or out-of-range values are clamped on parse.

| group | key | default |
|---|---|---|
| clock | `burstSamples`, `burstSpacingMs` | 10, 40 |
| | `fastIntervalMs` / `slowIntervalMs` / `stableUncertaintyUs` | 1000 / 3000 / 3000 |
| | `windowSize`, `maxSampleAgeMs`, `maxRttMs` | 64, 180000, 1500 |
| | `maxSkewPpm`, `residualSkewPpm`, `minSkewSpanMs`, `minSkewSamples`, `probeTimeoutMs` | 200, 10, 20000, 10, 2000 |
| scheduler | `minLeadMs`, `maxLeadMs`, `rttMultiplier`, `safetyMarginMs` | 250, 3000, 1.5, 120 |
| | `readinessTimeoutMs`, `lateJoinLeadMs`, `minScheduleAheadMs` | 8000, 400, 40 |
| drift | `reportIntervalActiveMs` / `reportIntervalIdleMs`, `settleTimeMs`, `latencyLearnDelayMs`, `medianWindow` | 500 / 2000, 1200, 2500, 5 |
| | `rateEnterThresholdUs` / `rateExitThresholdUs` | 8000 / 3000 |
| | `seekThresholdUs`, `seekThresholdNoRateUs`, `seekConfirmations`, `seekCooldownMs` | 250000, 45000, 2, 5000 |
| | `correctionHorizonMs`, `maxRateDelta`, `minRateStep` | 4000, 0.015, 0.0005 |
| membership | `heartbeatIntervalMs`, `detector` (`phi`\|`fixed`), `suspectPhi`, `failPhi`, `minSuspectAfterMs`, `minFailAfterMs`, `maxFailAfterMs`, `acceptablePauseMs`, `minStdDevMs`, `suspectAfterMs`, `failAfterMs` (fixed detector), `reconnectGraceMs` | 1000, fixed, 8, 12, 2000, 4000, 16000, 500, 200, 3000, 8000, 90000 |
| | `maxParticipants`, `handshakeTimeoutMs`, `maxAuthFailures`, `authWindowMs` | 16, 5000, 5, 60000 |

## 7. Liveness, failure and reconnection

- Both sides send `hb` every second. Any frame proves liveness.
- **Failure detection** (both directions) uses the fixed timeouts by default (*suspect* after 3 s, *failed* after 8 s of
  silence). The optional φ accrual detector (`detector: phi`; [research-next.md](research-next.md)) works as follows:
  - it learns the heartbeat inter-arrival distribution (last 300) and computes φ = −log₁₀ P(a heartbeat this late);
  - *suspect* at φ ≥ 8, *failed* at φ ≥ 12;
  - never suspect before 2 s, never failed before 4 s or before 1.25 × the longest gap the link survived in the window;
  - always failed at 16 s.

  φ was the default briefly, but on real phones it caused extra reconnects, so the default went back to `fixed`.
- **Coordinator → participant:** *suspect* is shown in the UI. *Failed* closes the link and marks the member
  `disconnected`. The member's slot (role, volume) is kept for the 90 s reconnect grace, then removed. Readiness
  barriers stop waiting for disconnected members.
- **Participant → coordinator:**
  - *Suspect* shows "coordinator not responding".
  - *Failed* closes and reconnects with exponential backoff (0.5 s × 2ⁿ, capped at 8 s, ±20 % jitter, at most 30
    attempts). After that the session fails with `unreachable: … the room may need to be recreated`.
  - When the link died by silence, failover additionally waits until nothing was heard for 8 s.
- While disconnected, a participant keeps playing the last timeline and refuses local control requests
  (`not_connected`). On reconnect it re-authenticates, receives the current state in `welcome`, runs a new clock burst,
  and joins the timeline. It emits `evt{rejoined}` once its measured error is back inside the correction band.
- A newer authenticated link for the same device supersedes the older one; frames from the old link are dropped.

### Failover (succession)

*Isolation hold-off:* after a *silent* loss (no closed connection), a phone that is next to promote itself but reached
none of the successors ahead of it waits 20 s longer and retries from the coordinator, because it is most likely the one
cut off.

1. **Candidates.** `successionOrder(state)` lists the participants with `canHost` and an `ep` whose `conn` is not
   `disconnected`, excluding `coord`: the `pref` device (original host) first when eligible, then list (admission)
   order. Every member computes it from its last state, so no election messages are needed.
2. **Trigger.** A member that lost its coordinator link and could not re-establish it for 2 s (`failoverAfter`) picks
   candidate *k*, starting at 0.
   - If *k* is itself, it starts a coordinator with the same `room` and key, `epoch + 1` and a new `inst`. It restores
     the last state with `tl.atUs` converted into its own clock using its offset estimate, keeps `tl.gen`, and drops
     `pending`.
   - Otherwise it connects to candidate *k*'s `ep`. After 3 failed attempts it moves to *k + 1*.
3. **Rejoin.** Members re-authenticate normally. A `challenge` with a higher `epoch` and a new `inst` means failover:
   clock samples are discarded, but the playing segment is kept, because the generation is unchanged.
4. **Roles.** The new coordinator re-applies the previous roles; the old host becomes `controller`.
5. **Fencing.** `epoch` is a fencing token: members follow the highest `(epoch, version)` they have seen and ignore
   state, redirects and handovers from lower epochs.

### Handback to the original host and planned transfers

`state.pref` names the device that should coordinate whenever it is present: the device that created the room.

| `t` | dir | body | purpose |
|---|---|---|---|
| `handover` | S→C | `{epoch, state}` | "Start a coordinator for this room at `epoch` with `state` (sender's clock domain)." |
| `handover.ack` | C→S | `{epoch, ok, err?}` | `ok`: already serving at `epoch` on its advertised `ep` port. |
| `redirect` | S→C | `{epoch, ep, reason}` | The room is now served at `ep` (`reason`: `handover` or `stepdown`). Reconnect immediately. |

1. **Handback** (preferred-leader rebalancing). A coordinator with `coord ≠ pref` checks every 100 ms: the `pref`
   member is connected, has `canHost` and `ep`, has been connected *without interruption* for `stableFor` (10 s;
   a suspect/disconnect restarts the window), reports clock uncertainty ≤ 20 ms, and there is no `pending` segment,
   open readiness barrier or calibration. It then sends `handover{epoch + 1, state}`.
2. The preferred device translates the timeline into its own clock (as in failover; generation kept), starts serving
   at `epoch + 1`, and answers `handover.ack{ok}`. It declines (`ok:false`) without a clock estimate or the ability to
   host.
3. On `ok`, the old coordinator sends `redirect{epoch + 1, ep}` to every other member, waits 0.5 s and closes the
   links **without** `bye` (a `bye` would end member sessions). Members reconnect at once; their audio keeps
   playing because the generation is unchanged. The old coordinator's own device becomes a guest.
4. On `ok:false` or no answer within 5 s: retry after 60 s, doubling up to 10 min (no flapping).
5. **Graceful leave.** A coordinator that is only standing in (after failover) and leaves hands the room to the
   first succession candidate the same way instead of closing it. The original host leaving ends the room (`bye`).
6. **Step-down** (split-brain resolution). A coordinator that sees a discovery beacon of its own room with a higher
   `epoch` (typically after its Wi-Fi came back) sends `redirect{thatEpoch, beacon address:port, stepdown}` to its
   members, closes without `bye`, and its own device joins the higher-epoch coordinator as a guest. The handback
   rule then returns the role to `pref`.
7. **Rejoin after a crash.** The app stores the room id, name and join key of a room it created (app-private
   storage; deleted when the user ends or leaves the party). When that room's beacon is seen, the home screen offers
   "Rejoin your party"; the device joins as a guest and step 1 applies.
8. **Not consensus.** Coordinator choice is deterministic priority (`pref`, then admission order) plus epoch
   fencing; there are no quorums. During a partition both sides keep playing; they converge when beacons cross
   again (step 6).

## 8. Track delivery (HTTP)

```
GET /tracks/<64 lowercase hex>
X-SyncSphere-Auth: <sessionId>.<expiryCoordMs>.<b64url(HMAC(xfer, "GET|/tracks/<id>|<expiry>")[0:16])>
Range: bytes=<start>-            (optional, single range)
```

| Status | Meaning |
|---|---|
| 200 / 206 | Full or partial content. `Accept-Ranges: bytes`, `ETag: "<id>"`. |
| 400 | Malformed id |
| 401 | Missing, invalid or expired token |
| 404 | Not a served playlist track |
| 413 | Over the transfer limit (512 MiB) |
| 416 | Bad range (`Content-Range: bytes */len`) |
| 429 | Too many concurrent transfers: 2 per session, 8 in total (`Retry-After: 2`) |

The client verifies SHA-256 before use and restarts once on mismatch.

### Uploads (guests adding songs)

```
PUT /uploads/<64 lowercase hex>
X-SyncSphere-Auth: <sessionId>.<expiryCoordMs>.<b64url(HMAC(xfer, "PUT|/uploads/<id>|<expiry>")[0:16])>
Content-Length: <bytes>
```

A member with control rights sends a song from its phone to the coordinator, then sends `addTrack`. The MAC covers
the method, so a download token cannot authorize an upload. The coordinator stores the body only if its SHA-256 equals
the id; from then on it serves the song under `/tracks/<id>` like any other.

| Status | Meaning |
|---|---|
| 201 | Stored |
| 400 | Malformed id or empty body |
| 401 | Missing, invalid or expired token |
| 403 | The member may not control the music (listener) |
| 405 | This coordinator does not accept uploads |
| 413 | Over the transfer limit (512 MiB) |
| 422 | Content does not match the id |
| 429 | This session already has an upload running (`Retry-After: 2`) |

After a failover, the new coordinator also serves songs it had downloaded (including uploaded ones), so they stay
playable.

### Phone-to-phone sharing (chunks)

Every device runs a *peer file server* (port in `caps.pport`, published as the participant's `peer`). Peer servers
and the coordinator answer:

| Request | Answer |
|---|---|
| `GET /tracks/<id>/chunks` | `{"size": N, "hashes": ["<sha256 of chunk 0>", …]}` (512 KiB chunks; the last may be shorter) |
| `GET /tracks/<id>/have` | `{"n": chunks, "bits": "<base64 bitmap>"}`, all ones for a complete copy |
| `GET /tracks/<id>` + `Range` | The bytes, from a complete copy or from chunks a partial copy already has (otherwise 416) |

Peer requests carry `X-SyncSphere-Auth: <deviceId>.<expiryCoordMs>.<b64url(HMAC(peerKey, "GET|<path>|<expiry>")[0:16])>`,
where `peerKey = HMAC(roomKey, "peer|<roomId>")` is known to every member. The coordinator accepts session tokens and
peer tokens. Uploads only ever accept session tokens.

A downloader:
1. fetches a chunk list from the coordinator or any peer and checks it against `croot`;
2. polls the peers' `/have` every 2 s;
3. fetches missing chunks rarest-first (4 in parallel, at most 2 per source, peers before the coordinator);
4. checks each chunk's hash, and stops using a source after 2 bad chunks;
5. checks the assembled file against the track id.

Partial copies are kept as `<id>.swarm` + `<id>.have` + `<id>.chunks` in the cache (resumable) and are served to
others while downloading. Without progress for 30 s, or without a `croot`, the device downloads the whole file from
the coordinator as before. Tracks with a `src` URL use the source first (§4).

## 9. Discovery beacon (UDP 47801)

```json
{"app":"syncsphere","v":1,"room":"K7Q2M9","name":"Living room","coord":"dev-abc","epoch":1,"port":47800,"n":3}
```

Sent every second to `255.255.255.255` and to each interface's /24 broadcast address. Beacons carry no secrets and
are only hints: the listener takes the host from the datagram source, entries expire after 5 s, and anything
malformed or over 1 KiB is dropped.

## 10. Versioning policy

- New optional fields can be added within v1 (receivers ignore unknown keys).
- New message types can be added within v1 (receivers ignore unknown types).
- New enum values (control actions such as `setRepeat`, `setShuffle`, `setChannelRole`, `calibrate`,
  `setCalibration`) are also added within v1, but an older coordinator rejects a control it cannot parse, so every
  device in a room should run the same app version.
- Changing the meaning or the requiredness of an existing field requires a new protocol version, negotiated through
  `pmin`/`pmax` and `challenge.proto`.
