/// Handback to the preferred (original) host and split-brain step-down at
/// the protocol level (raw clients against a real coordinator, fake time).
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

import 'coordinator_test.dart' show Fixture, RawClient;

const _hostCaps = DeviceCapabilities(rateControl: true, backend: 'test', canHost: true, failoverPort: 47800);

/// Raw clients must send traffic or the coordinator marks them unresponsive
/// (which also resets the handback stability window).
(RawClient, WelcomeMsg?) _join(Fixture f, String id, {DeviceCapabilities caps = _hostCaps}) {
  final (c, w) = f.join(id, caps: caps);
  Timer.periodic(const Duration(milliseconds: 500), (t) {
    if (c.closed) {
      t.cancel();
    } else {
      c.send(HeartbeatMsg(f.clock.nowMicros()));
    }
  });
  return (c, w);
}

void main() {
  test('a new room prefers its own host; no handback is attempted', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      expect(f.coord.state.preferredCoordinator, 'host-device');
      final (a, _) = _join(f, 'dev-a');
      fa.elapse(const Duration(seconds: 30));
      expect(a.received.whereType<HandoverMsg>(), isEmpty);
    });
  });

  test('successor hands back after the preferred host is stable for 10 s, then redirects everyone', () {
    fakeAsync((fa) {
      // A successor at epoch 2 whose room prefers "orig".
      final f = Fixture(fa, preferredCoordinator: 'orig-device', epoch: 2);
      final (other, _) = _join(f, 'other-device');
      final (orig, _) = _join(f, 'orig-device');
      fa.elapse(const Duration(seconds: 9));
      expect(orig.received.whereType<HandoverMsg>(), isEmpty, reason: 'not stable long enough yet');
      fa.elapse(const Duration(seconds: 2));
      final h = orig.last<HandoverMsg>()!;
      expect(h.epoch, 3);
      expect(h.state.preferredCoordinator, 'orig-device');
      var stepped = '';
      f.coord.onSteppedDown = (ep, epoch, reason) => stepped = '$ep@$epoch/$reason';

      orig.send(const HandoverAckMsg(epoch: 3, ok: true));
      fa.elapse(const Duration(milliseconds: 50));
      final r = other.last<RedirectMsg>()!;
      expect(r.epoch, 3);
      expect(r.endpoint, 'orig-device:47800');
      expect(r.reason, 'handover');
      expect(orig.received.whereType<RedirectMsg>(), isEmpty, reason: 'the new host is not redirected to itself');
      expect(stepped, 'orig-device:47800@3/handover');
      fa.elapse(const Duration(seconds: 1));
      expect(other.closed, isTrue, reason: 'old coordinator closes after the grace period');
      expect(other.received.whereType<ByeMsg>(), isEmpty, reason: 'no bye: that would end the member session');
    });
  });

  test('declined or unanswered handover backs off instead of flapping', () {
    fakeAsync((fa) {
      final f = Fixture(fa, preferredCoordinator: 'orig-device', epoch: 2);
      final (orig, _) = _join(f, 'orig-device');
      fa.elapse(const Duration(seconds: 11));
      expect(orig.received.whereType<HandoverMsg>().length, 1);
      orig.send(const HandoverAckMsg(epoch: 3, ok: false, error: 'clock not synchronized yet'));
      fa.elapse(const Duration(seconds: 30));
      expect(orig.received.whereType<HandoverMsg>().length, 1, reason: 'backing off 60 s');
      fa.elapse(const Duration(seconds: 35));
      expect(orig.received.whereType<HandoverMsg>().length, 2, reason: 'retried after the backoff');
      // No answer at all: timeout, then the backoff doubles (120 s).
      fa.elapse(const Duration(seconds: 100));
      expect(orig.received.whereType<HandoverMsg>().length, 2);
      fa.elapse(const Duration(seconds: 30));
      expect(orig.received.whereType<HandoverMsg>().length, 3);
      expect(f.coord.state.coordinatorEpoch, 2, reason: 'still serving');
    });
  });

  test('no handback while a calibration runs or a start is being negotiated', () {
    fakeAsync((fa) {
      final f = Fixture(fa, preferredCoordinator: 'orig-device', epoch: 2, defaultRole: ParticipantRole.controller);
      final (orig, _) = _join(f, 'orig-device');
      // A pending segment that never becomes ready keeps the barrier open
      // until its timeout; play right before the stability window ends.
      fa.elapse(const Duration(seconds: 9, milliseconds: 900));
      orig.send(ControlMsg(requestId: 1, action: ControlAction.play, baseVersion: f.coord.state.version));
      fa.elapse(const Duration(milliseconds: 500));
      expect(f.coord.state.pending, isNotNull);
      expect(orig.received.whereType<HandoverMsg>(), isEmpty);
    });
  });

  test('split brain: a coordinator that learns of a higher epoch steps down and redirects its members', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      final (a, _) = _join(f, 'dev-a');
      f.coord.stepDown(endpoint: 'b:47800', epoch: 1); // not higher: ignored
      fa.elapse(const Duration(milliseconds: 50));
      expect(a.received.whereType<RedirectMsg>(), isEmpty);
      f.coord.stepDown(endpoint: 'b:47800', epoch: 2);
      fa.elapse(const Duration(seconds: 1));
      final r = a.last<RedirectMsg>()!;
      expect(r.endpoint, 'b:47800');
      expect(r.reason, 'stepdown');
      expect(a.closed, isTrue);
      expect(a.received.whereType<ByeMsg>(), isEmpty);
    });
  });

  test('graceful leave: the coordinator hands the room to the next phone instead of closing it', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      final (first, _) = _join(f, 'first-device');
      final (second, _) = _join(f, 'second-device');
      bool? result;
      f.coord.handOff().then((v) => result = v);
      fa.elapse(const Duration(milliseconds: 50));
      final h = first.last<HandoverMsg>()!;
      expect(second.received.whereType<HandoverMsg>(), isEmpty);
      first.send(HandoverAckMsg(epoch: h.epoch, ok: true));
      fa.elapse(const Duration(seconds: 1));
      expect(result, isTrue);
      expect(second.last<RedirectMsg>()!.endpoint, 'first-device:47800');
      expect(second.received.whereType<ByeMsg>(), isEmpty);
    });
  });

  test('graceful leave falls through declining phones and reports when nobody can host', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      final (first, _) = _join(f, 'first-device');
      final (second, _) = _join(f, 'second-device');
      _join(f, 'cannot-host', caps: const DeviceCapabilities(rateControl: true, backend: 'test'));
      bool? result;
      f.coord.handOff().then((v) => result = v);
      fa.elapse(const Duration(milliseconds: 50));
      first.send(HandoverAckMsg(epoch: first.last<HandoverMsg>()!.epoch, ok: false, error: 'busy'));
      fa.elapse(const Duration(milliseconds: 50));
      final h2 = second.last<HandoverMsg>()!;
      second.send(HandoverAckMsg(epoch: h2.epoch, ok: false, error: 'busy'));
      fa.elapse(const Duration(milliseconds: 50));
      expect(result, isFalse);
    });
  });

  test('handover messages round-trip', () {
    final c = FrameCodec(), s = FrameCodec();
    final keys = RoomKey.derive(roomId: 'r', joinKey: 'k', iterations: 1).sessionKeys('d', 'a', 'b');
    c.activate(sendKey: keys.clientToServer, recvKey: keys.serverToClient);
    s.activate(sendKey: keys.serverToClient, recvKey: keys.clientToServer);
    const st = RoomState(
        roomId: 'r', roomName: 'R', coordinatorId: 'b', coordinatorEpoch: 2, version: 3,
        timeline: PlaybackTimeline.idle(), preferredCoordinator: 'orig-device');
    final h = c.decode(s.encode(const HandoverMsg(epoch: 3, state: st))) as HandoverMsg;
    expect(h.state.preferredCoordinator, 'orig-device');
    final a = s.decode(c.encode(const HandoverAckMsg(epoch: 3, ok: false, error: 'x'))) as HandoverAckMsg;
    expect((a.ok, a.error), (false, 'x'));
    final r = c.decode(s.encode(const RedirectMsg(epoch: 3, endpoint: 'h:1', reason: 'handover'))) as RedirectMsg;
    expect(r.endpoint, 'h:1');
  });
}
