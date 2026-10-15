# Done (see commit): "End party" leaves guests playing, can't rejoin, can't add songs in a party (+ move work to laptop)

## Context
Real-phone test: sync was good, but (1) after the host tapped "End party" the two guests kept playing,
(2) the user could not join back, (3) songs cannot be added once in a party. Cloud credit is nearly used up
($13 left), so the work continues on the user's laptop with Claude Code (branch
`claude/syncsphere-music-sync-1zfnjc`).

## Root causes (found by reading the code)
1. **Guests keep playing.** The host's `bye` makes the guest session fail (`ParticipantSession._fatal`,
   `packages/syncsphere_core/lib/src/participant/participant_session.dart`), which calls
   `engine.onConnectionChanged(false)`. That path is designed for temporary disconnects: the engine keeps
   playing the last timeline (`playback_engine.dart` `onConnectionChanged`). The app's `RoomController`
   (`app/lib/src/state/room_controller.dart`) only records the error, so the guest stays in the room screen and
   keeps playing. Also `RoomCoordinator.close()` closes links right after sending `bye`; if the bye is lost,
   guests now fail over (every session has a failover delegate since the handback work) and keep the party going
   without the host.
2. **Can't join back.** Follows from 1: no party exists any more, but the guests look like they are still in one.
3. **Can't add songs in a party.** Importing only exists on the home screen ("My music → Add"), which is not
   reachable while in a party; the Queue tab's "Add songs" (`app/lib/src/ui/queue_view.dart`) only lists songs
   already in the library.

## Fixes
1. Core: when the session fails with `room_closed` (host ended the party), stop playback
   (`backend.stop()` via the engine, e.g. a new `engine.stopAll()`), and make the session report "ended" rather
   than reconnecting/failing over.
2. Core: `RoomCoordinator.close()` waits ~300 ms after sending `bye` before closing links (so the bye arrives);
   guests that got `bye` never start failover.
3. App: `RoomController` reacts to phase `failed` with `room_closed` by leaving automatically → home screen with
   "The host ended the party". Same for other fatal errors (show message, return home).
4. App: Queue tab "Add songs" offers "From my music" and "From this phone…" (file picker → `LibraryNotifier.importFiles`
   → `RoomController.addTracks`). Guests see "Only the host can add songs" (guest uploads = later feature).
5. Tests: core (bye stops audio, no failover after bye), app room_service_test (host ends party → guests stop and
   leave), screens test (Queue add-from-phone visible for host).

## Continue on the laptop
1. Install: Git, Flutter (stable), Android Studio (SDK + a phone with USB debugging), Claude Code
   (`npm install -g @anthropic-ai/claude-code`).
2. `git clone https://github.com/sudu787/Distributed-.git && cd Distributed- && git checkout claude/syncsphere-music-sync-1zfnjc`
3. `cd app && flutter pub get && flutter run` (installs directly on a USB-connected phone; no GitHub download needed).
4. Start `claude` in the repo folder and paste: "Implement the plan in docs/next-fixes.md" (save this plan there),
   or describe the three bugs; tests: `cd packages/syncsphere_core && dart test`, `cd app && flutter test`.

## Verification
- Unit/app tests above pass; on phones: host taps End party → guests stop within ~1 s and return home with a
  message; host can create a new party and guests can join it; host can add a song from the phone while in a party.
