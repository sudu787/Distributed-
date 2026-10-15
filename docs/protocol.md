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
| `caps` | object | `{rate: bool, backend: string, lan: bool, canHost: bool, fport?: int}`. `fport` is the port this device would serve on if promoted (failover). |

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
| `ctl` | C→S | `{rid, act, base, posUs?, track?, val?, dev?, role?}` | Control request (§5) |
| `ctl.ack` | S→C | `{rid, ok, err?, ver}` | Result. `ver` = state version after applying it. |
| `rep` | C→S | `{gen, at, pos, exp, err, rate, buf, off, unc, rtt, mode, ps}` | Sync report: coordinator-domain measurement time, rendered and expected position, error = pos − exp (µs), current rate, buffered µs, clock offset and uncertainty, RTT p95, correction mode (`idle|waiting|inSync|rateCorrecting|resyncing`), player state |
| `evt` | C→S | `{kind, gen, detail?, data}` | `started` (data: `startErrorUs`, `playCallLateUs`, `latencyCompUs`), `lateJoin` (`lateUs`), `resync` (`posUs`), `stall`, `rejoined` (`recoveryUs`, `errorUs`), `error` |
| `avail` | C→S | `{tracks:[{id, a}]}` | Track availability: `unknown|available|fetching|missing|mismatch`. Partial updates allowed. |
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
             "track": "available", "canHost": false},
            {"id": "dev-def", "name": "Kitchen", "role": "controller", "conn": "connected", "vol": 1.0,
             "track": "available", "canHost": true, "ep": "192.168.1.31:47800"}],
  "dist": "auto"
}
```

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

`base` is the state version the sender's UI showed. `timelineVersion` is the version at which the timeline, the pending
segment or the playlist last changed. An action that could overwrite a newer conflicting intent (seeking within a track
that someone else has just replaced) is refused with `stale_version`; the UI refreshes and the user retries. Membership
and volume churn do not make playback commands stale. Ack error codes: `unauthorized`, `stale_version`, `invalid`,
`unknown_track`, `nothing_to_play`, `not_connected`, `timeout` (client side).

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
| drift | `reportIntervalActiveMs` / `reportIntervalIdleMs`, `settleTimeMs`, `medianWindow` | 500 / 2000, 1200, 5 |
| | `rateEnterThresholdUs` / `rateExitThresholdUs` | 8000 / 3000 |
| | `seekThresholdUs`, `seekThresholdNoRateUs`, `seekConfirmations`, `seekCooldownMs` | 250000, 45000, 2, 5000 |
| | `correctionHorizonMs`, `maxRateDelta`, `minRateStep` | 4000, 0.015, 0.0005 |
| membership | `heartbeatIntervalMs`, `suspectAfterMs`, `failAfterMs`, `reconnectGraceMs` | 1000, 3000, 8000, 90000 |
| | `maxParticipants`, `handshakeTimeoutMs`, `maxAuthFailures`, `authWindowMs` | 16, 5000, 5, 60000 |

## 7. Liveness, failure and reconnection

- Both sides send `hb` every second. Any frame resets the silence timer.
- **Coordinator → participant:** silent for 3 s → `suspect` (shown in the UI); 8 s → link closed and the member marked
  `disconnected`. The member's slot (role, volume) is kept for the 90 s reconnect grace, then removed. Readiness
  barriers stop waiting for disconnected members.
- **Participant → coordinator:** silent for 3 s → "coordinator not responding"; 8 s → close and reconnect with
  exponential backoff (0.5 s × 2ⁿ, capped at 8 s, ±20 % jitter, at most 30 attempts). After that the session fails with
  `unreachable: … the room may need to be recreated`.
- While disconnected, a participant keeps playing the last timeline and refuses local control requests
  (`not_connected`). On reconnect it re-authenticates, receives the current state in `welcome`, runs a new clock burst,
  and joins the timeline. It emits `evt{rejoined}` once its measured error is back inside the correction band.
- A newer authenticated link for the same device supersedes the older one; frames from the old link are dropped.

### Failover (succession)

1. **Candidates.** `successionOrder(state)` lists the participants with `canHost` and an `ep` whose `conn` is not
   `disconnected`, excluding `coord`, in list (admission) order. Every member computes it from its last state.
2. **Trigger.** A member that lost its coordinator link and could not re-establish it for 2 s (`failoverAfter`) picks
   candidate *k*, starting at 0.
   - If *k* is itself, it starts a coordinator with the same `room` and key, `epoch + 1` and a new `inst`. It restores
     the last state with `tl.atUs` converted into its own clock using its offset estimate, keeps `tl.gen`, and drops
     `pending`.
   - Otherwise it connects to candidate *k*'s `ep`. After 3 failed attempts it moves to *k + 1*.
3. **Rejoin.** Members re-authenticate normally. A `challenge` with a higher `epoch` and a new `inst` means failover:
   clock samples are discarded, but the playing segment is kept, because the generation is unchanged.
4. **Roles.** The new coordinator re-applies the previous roles; the old host becomes `controller`.
5. **Not consensus.** Under a partition both sides may run coordinators. Members follow the highest
   `(epoch, version)` they have seen.

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
- Changing the meaning or the requiredness of an existing field requires a new protocol version, negotiated through
  `pmin`/`pmax` and `challenge.proto`.
