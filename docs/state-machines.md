# State machines and sequence diagrams

## Participant session (connection lifecycle)

```mermaid
stateDiagram-v2
  [*] --> idle
  idle --> connecting: start()
  connecting --> authenticating: socket open, hello sent
  authenticating --> syncing: welcome verified
  authenticating --> failed: reject auth_failed / wrong_room / unsupported_version
  syncing --> joined: ≥3 clock samples accepted
  joined --> reconnecting: link closed / coordinator silent ≥ failAfter
  syncing --> reconnecting: link closed
  connecting --> reconnecting: connect error
  reconnecting --> connecting: backoff elapsed
  reconnecting --> failed: attempts exhausted ("room may need to be recreated")
  joined --> failed: bye from coordinator (room closed)
  joined --> closed: leave()
  failed --> [*]
  closed --> [*]
```

Invariants:
- Control requests are only sent in `syncing` or `joined`. In any other phase they fail locally with `not_connected`.
- Playback continues in `reconnecting`, following the last timeline.
- A change of coordinator instance (`challenge.inst`) discards all clock samples.

## Coordinator playback state

```mermaid
stateDiagram-v2
  [*] --> Idle
  Idle --> Preparing: play / setTrack (new gen, pending)
  Preparing --> Playing: barrier complete (all ready or timeout) → anchor = now + lead
  Preparing --> Idle: nobody ready (abort)
  Preparing --> Paused: pause, or seek while paused
  Playing --> Preparing: seek / setTrack / next / prev / auto-advance (new gen)
  Playing --> Paused: pause (anchor = now + lead, pos = expected(anchor))
  Paused --> Preparing: play (resume at paused position)
  Paused --> Paused: seek (new gen, new position)
  Playing --> Paused: end of playlist (stop at 0)
```

Every transition increments `version`. Every transition except a pure membership or volume change also increments
`generation` (the Idle state has generation 0).

## Participant playback engine (per segment)

```mermaid
stateDiagram-v2
  [*] --> preparing: pending g / late join
  preparing --> prepared: backend ready → send ready(g)
  preparing --> [*]: superseded (newer gen) / error → ready(ok=false)
  prepared --> scheduled: timeline g playing and target ≥ now + minScheduleAhead
  prepared --> preparing: target already passed → late join at future position
  scheduled --> playing: native playCalled
  playing --> pausing: paused timeline
  pausing --> paused: native paused (then seek to anchor position)
  paused --> scheduled: resume (same player reused if positioned)
  playing --> [*]: replaced by next segment's start
```

## Drift controller

```mermaid
stateDiagram-v2
  [*] --> waiting
  waiting --> inSync: ≥3 samples, |e| ≤ enter
  waiting --> rateCorrecting: ≥3 samples, |e| > enter
  inSync --> rateCorrecting: |e| > enter (8 ms)
  rateCorrecting --> inSync: |e| < exit (3 ms)
  inSync --> resyncing: |e| − unc > seekThr for 2 samples, cooldown passed
  rateCorrecting --> resyncing: same
  resyncing --> waiting: standby segment started (reset)
```

`e` is the median of the last 5 measurements. Without rate control there is no `rateCorrecting` state, and the seek
threshold is 45 ms instead of 250 ms.

## Membership (coordinator view of one device)

```mermaid
stateDiagram-v2
  [*] --> connected: auth ok (new slot or resume)
  connected --> suspect: silent ≥ 3 s
  suspect --> connected: any frame
  suspect --> disconnected: silent ≥ 8 s (link closed)
  connected --> disconnected: link closed / superseded / integrity failure
  disconnected --> connected: re-auth within 90 s (same role, volume)
  disconnected --> removed: grace expired
  connected --> removed: bye
  removed --> [*]
```

## Sequence: pause, resume and seek

```mermaid
sequenceDiagram
  autonumber
  participant U as Controller
  participant C as Coordinator
  participant A as Participant A
  participant B as Participant B
  U->>C: ctl pause (base v)
  C->>C: P = now + lead; pos = expected(P); gen+1
  C-->>A: state: paused @P pos
  C-->>B: state: paused @P pos
  A->>A: pauseAt(local(P)) then seek(pos)
  B->>B: pauseAt(local(P)) then seek(pos)
  U->>C: ctl play
  C-->>A: state: pending g+2 at pos
  C-->>B: state: pending g+2 at pos
  A->>C: ready (reused paused player)
  B->>C: ready
  C-->>A: state: playing g+2 @T
  C-->>B: state: playing g+2 @T
  U->>C: ctl seek 2:00 (base v')
  C-->>A: state: pending g+3 at 120 s
  C-->>B: state: pending g+3 at 120 s
  Note over A,B: standby players buffer at 120 s while g+2 keeps playing
  A->>C: ready
  B->>C: ready
  C-->>A: state: playing g+3 @T'
  C-->>B: state: playing g+3 @T'
  Note over A,B: at local(T') the standby starts and the old player is paused/released
```

## Sequence: reconnection

```mermaid
sequenceDiagram
  autonumber
  participant P as Participant
  participant C as Coordinator
  Note over P: Wi-Fi drops. Audio keeps playing on the last timeline.
  C->>C: silent 3 s → suspect; 8 s → disconnected (slot kept 90 s)
  P->>P: silent 8 s → link down → backoff 0.5, 1, 2, … s
  P->>C: hello / auth (same deviceId, resume=session)
  C->>P: welcome {current state vN}
  P->>C: clk.req burst
  alt same generation still playing
    P->>P: keep active segment; drift loop corrects small offset
  else timeline changed while away
    P->>P: late join: prepare at expected(now + lead), start at exact time
  end
  P->>C: evt rejoined {recoveryUs, errorUs}
```

## Sequence: coordinator loss (current behavior)

```mermaid
sequenceDiagram
  participant C as Coordinator (host)
  participant P as Participants
  C--xP: host process killed / host leaves Wi-Fi
  P->>P: free-run on last timeline, show "Reconnecting"
  loop up to 30 attempts with backoff (≈ 3–4 min)
    P->>C: connect
  end
  P->>P: phase failed: "coordinator unreachable; the room may need to be recreated"
```

Automatic succession to a new coordinator is designed in [roadmap.md](roadmap.md#coordinator-failover-milestone).
It is not claimed as implemented.
