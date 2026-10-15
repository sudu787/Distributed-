import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

/// Minimal protocol client used to poke the coordinator directly.
class RawClient {
  final MessageConnection conn;
  final FrameCodec codec = FrameCodec();
  final List<Message> received = [];
  final List<ProtocolException> errors = [];
  late final StreamSubscription<String> sub;
  bool closed = false;

  RawClient(this.conn) {
    sub = conn.incoming.listen((f) {
      try {
        received.add(codec.decode(f));
      } on ProtocolException catch (e) {
        errors.add(e);
      }
    }, onDone: () => closed = true);
  }

  void send(Message m) => conn.send(codec.encode(m));
  T? last<T>() => received.whereType<T>().isEmpty ? null : received.whereType<T>().last;
}

const kKey = 'TESTKEY1';
const tracks = [
  TrackInfo(id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', title: 'A', sizeBytes: 1, durationUs: 60000000),
  TrackInfo(id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', title: 'B', sizeBytes: 1, durationUs: 60000000),
];

class Fixture {
  final FakeAsync fa;
  late final ManualClockFromFake clock = ManualClockFromFake(fa);
  late final MemoryNetwork net = MemoryNetwork(clock: clock);
  late final RoomCoordinator coord;

  Fixture(this.fa, {ParticipantRole defaultRole = ParticipantRole.listener, int maxParticipants = 16}) {
    coord = RoomCoordinator(
      options: CoordinatorOptions(
        roomId: 'room-1',
        roomName: 'Test',
        coordinatorId: 'host-device',
        joinKey: kKey,
        kdfIterations: 5,
        defaultRole: defaultRole,
        config: SyncConfig(membership: MembershipConfig(maxParticipants: maxParticipants)),
      ),
      clock: clock,
    );
    coord.setPlaylist(tracks);
    coord.serve(net.listen('coord'));
    coord.start();
  }

  Link link() => Link(uplink: const LinkProfile(), downlink: const LinkProfile());

  RawClient raw(String name) {
    late MessageConnection c;
    net.connect(name, 'coord', link()).then((v) => c = v);
    fa.elapse(const Duration(milliseconds: 10));
    return RawClient(c);
  }

  /// Completes the handshake; returns the client and the welcome.
  (RawClient, WelcomeMsg?) join(String deviceId, {String key = kKey}) {
    final c = raw(deviceId);
    const nonce = 'client-nonce-123456';
    c.send(const HelloMsg(
      deviceId: 'x',
      displayName: 'x',
      platform: 'test',
      clientNonce: nonce,
      caps: DeviceCapabilities(rateControl: true, backend: 'test'),
    ).withDevice(deviceId));
    fa.elapse(const Duration(milliseconds: 10));
    final ch = c.last<ChallengeMsg>();
    if (ch == null) return (c, null);
    final rk = RoomKey.derive(roomId: ch.roomId, joinKey: key, iterations: ch.kdfIterations);
    c.send(AuthMsg(proof: rk.clientProof(deviceId, nonce, ch.serverNonce)));
    final keys = rk.sessionKeys(deviceId, nonce, ch.serverNonce);
    c.codec.activate(sendKey: keys.clientToServer, recvKey: keys.serverToClient);
    fa.elapse(const Duration(milliseconds: 10));
    return (c, c.last<WelcomeMsg>());
  }
}

class ManualClockFromFake implements MonotonicClock {
  final FakeAsync fa;
  ManualClockFromFake(this.fa);
  @override
  int nowMicros() => fa.elapsed.inMicroseconds + 1000000;
}

extension on HelloMsg {
  HelloMsg withDevice(String id) => HelloMsg(
      deviceId: id,
      displayName: id,
      platform: platform,
      clientNonce: clientNonce,
      caps: caps);
}

void main() {
  test('join handshake: welcome with state, mutual proof and role', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      final (host, hw) = f.join('host-device');
      expect(hw, isNotNull);
      expect(hw!.role, ParticipantRole.host);
      final (p, w) = f.join('phone-1');
      expect(w!.role, ParticipantRole.listener);
      expect(w.state.playlist.length, 2);
      final rk = RoomKey.derive(roomId: 'room-1', joinKey: kKey, iterations: 5);
      final ch = p.received.whereType<ChallengeMsg>().single;
      expect(w.serverProof, rk.serverProof('phone-1', 'client-nonce-123456', ch.serverNonce));
      // The welcome must be the first message after the challenge.
      final idx = p.received.indexWhere((m) => m is WelcomeMsg);
      expect(p.received.sublist(0, idx).any((m) => m is StateMsg), isFalse);
      expect(f.coord.state.participants.length, 2);
      expect(host.closed, isFalse);
    });
  });

  test('wrong join key is rejected and rate limited', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      for (var i = 0; i < 5; i++) {
        final (c, w) = f.join('attacker', key: 'WRONG$i');
        expect(w, isNull);
        expect(c.closed, isTrue);
      }
      // Now even the right key is refused for a while from this address.
      final c = f.raw('attacker');
      c.send(const HelloMsg(
          deviceId: 'attacker',
          displayName: 'a',
          platform: 't',
          clientNonce: 'client-nonce-123456',
          caps: DeviceCapabilities(rateControl: true, backend: 't')));
      fa.elapse(const Duration(milliseconds: 10));
      expect(c.last<RejectMsg>()?.code, RejectCode.rateLimited);
      fa.elapse(const Duration(minutes: 2));
      final (_, w) = f.join('attacker');
      expect(w, isNotNull);
    });
  });

  test('unauthenticated control messages are refused', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      final c = f.raw('evil');
      // Hand-craft an unauthenticated control frame.
      c.conn.send('-.{"v":1,"t":"ctl","s":1,"b":{"rid":1,"act":"play","base":0}}');
      fa.elapse(const Duration(milliseconds: 10));
      expect(c.closed, isTrue);
      expect(f.coord.state.pending, isNull);
    });
  });

  test('listener cannot control playback; host can promote', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      final (host, _) = f.join('host-device');
      final (p, _) = f.join('phone-1');
      p.send(ControlMsg(requestId: 1, action: ControlAction.play, baseVersion: f.coord.state.version));
      fa.elapse(const Duration(milliseconds: 10));
      expect(p.last<ControlAckMsg>()!.error, ControlError.unauthorized);
      expect(f.coord.state.pending, isNull);

      // Listener may change its own volume, not others'.
      p.send(const ControlMsg(requestId: 2, action: ControlAction.deviceVolume, baseVersion: 0, value: 0.3));
      p.send(const ControlMsg(
          requestId: 3, action: ControlAction.deviceVolume, baseVersion: 0, value: 0.3, targetDevice: 'host-device'));
      fa.elapse(const Duration(milliseconds: 10));
      final acks = p.received.whereType<ControlAckMsg>().toList();
      expect(acks[1].accepted, isTrue);
      expect(acks[2].error, ControlError.unauthorized);

      host.send(const ControlMsg(
          requestId: 1, action: ControlAction.setRole, baseVersion: 0, targetDevice: 'phone-1', role: ParticipantRole.controller));
      fa.elapse(const Duration(milliseconds: 10));
      expect(host.last<ControlAckMsg>()!.accepted, isTrue);
      expect(f.coord.state.participant('phone-1')!.role, ParticipantRole.controller);
      // Nobody can make themselves host.
      host.send(const ControlMsg(
          requestId: 2, action: ControlAction.setRole, baseVersion: 0, targetDevice: 'phone-1', role: ParticipantRole.host));
      fa.elapse(const Duration(milliseconds: 10));
      expect(host.last<ControlAckMsg>()!.accepted, isFalse);
    });
  });

  test('readiness barrier then future scheduled start', () {
    fakeAsync((fa) {
      final f = Fixture(fa, defaultRole: ParticipantRole.controller);
      final (host, _) = f.join('host-device');
      final (p, _) = f.join('phone-1');
      host.send(ControlMsg(requestId: 1, action: ControlAction.play, baseVersion: f.coord.state.version));
      fa.elapse(const Duration(milliseconds: 10));
      final pending = f.coord.state.pending!;
      expect(f.coord.state.timeline.status, PlaybackStatus.idle);
      host.send(ReadyMsg(generation: pending.generation, trackId: pending.trackId, ok: true, rttP95Us: 4000, startLatencyUs: 50000));
      fa.elapse(const Duration(milliseconds: 10));
      expect(f.coord.state.timeline.status, PlaybackStatus.idle, reason: 'still waiting for phone-1');
      // A stale ready (wrong generation) must not count.
      p.send(ReadyMsg(generation: pending.generation - 1, trackId: pending.trackId, ok: true));
      fa.elapse(const Duration(milliseconds: 10));
      expect(f.coord.state.timeline.status, PlaybackStatus.idle);
      p.send(ReadyMsg(generation: pending.generation, trackId: pending.trackId, ok: true, rttP95Us: 30000, startLatencyUs: 120000));
      fa.elapse(const Duration(milliseconds: 10));
      final tl = f.coord.state.timeline;
      expect(tl.status, PlaybackStatus.playing);
      expect(tl.generation, pending.generation);
      final now = f.clock.nowMicros();
      // lead = 30 ms × 1.5 + 120 ms + 0 + 120 ms safety = 285 ms
      expect(tl.anchorCoordUs - now, closeTo(285000, 15000));
      expect(f.coord.state.pending, isNull);
    });
  });

  test('readiness timeout starts with ready participants only', () {
    fakeAsync((fa) {
      final f = Fixture(fa, defaultRole: ParticipantRole.controller);
      final (host, _) = f.join('host-device');
      f.join('slow-phone');
      host.send(ControlMsg(requestId: 1, action: ControlAction.play, baseVersion: f.coord.state.version));
      fa.elapse(const Duration(milliseconds: 10));
      final pending = f.coord.state.pending!;
      host.send(ReadyMsg(generation: pending.generation, trackId: pending.trackId, ok: true));
      fa.elapse(const Duration(seconds: 9));
      expect(f.coord.state.timeline.status, PlaybackStatus.playing);
    });
  });

  test('stale seek is rejected after a concurrent track change', () {
    fakeAsync((fa) {
      final f = Fixture(fa, defaultRole: ParticipantRole.controller);
      final (a, _) = f.join('host-device');
      final (b, _) = f.join('phone-1');
      final base = f.coord.state.version;
      a.send(ControlMsg(requestId: 1, action: ControlAction.setTrack, baseVersion: base, trackId: tracks[1].id));
      fa.elapse(const Duration(milliseconds: 10));
      expect(a.last<ControlAckMsg>()!.accepted, isTrue);
      // b still shows the old state and asks to seek: must be refused.
      b.send(ControlMsg(requestId: 1, action: ControlAction.seek, baseVersion: base, positionUs: 30000000));
      fa.elapse(const Duration(milliseconds: 10));
      expect(b.last<ControlAckMsg>()!.error, ControlError.staleVersion);
      // Pause is idempotent and never "stale".
      b.send(ControlMsg(requestId: 2, action: ControlAction.pause, baseVersion: base));
      fa.elapse(const Duration(milliseconds: 10));
      expect(b.last<ControlAckMsg>()!.accepted, isTrue);
    });
  });

  test('versions increase monotonically and duplicates are harmless', () {
    fakeAsync((fa) {
      final f = Fixture(fa, defaultRole: ParticipantRole.controller);
      final (a, _) = f.join('host-device');
      a.send(ControlMsg(requestId: 1, action: ControlAction.masterVolume, baseVersion: 0, value: 0.5));
      a.send(ControlMsg(requestId: 2, action: ControlAction.masterVolume, baseVersion: 0, value: 0.5));
      fa.elapse(const Duration(milliseconds: 10));
      final versions = a.received.whereType<StateMsg>().map((s) => s.state.version).toList();
      for (var i = 1; i < versions.length; i++) {
        expect(versions[i], greaterThan(versions[i - 1]));
      }
      expect(f.coord.state.masterVolume, 0.5);
    });
  });

  test('replayed authenticated frame closes the link', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      final (c, _) = f.join('phone-1');
      final frame = c.codec.encode(const HeartbeatMsg(1));
      c.conn.send(frame);
      c.conn.send(frame);
      fa.elapse(const Duration(milliseconds: 10));
      expect(c.closed, isTrue);
    });
  });

  test('malformed but authenticated messages get errors, not crashes', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      final (c, _) = f.join('phone-1');
      c.send(const UnknownMessage('ctl', {'rid': 'not-a-number'}));
      fa.elapse(const Duration(milliseconds: 10));
      expect(c.last<ErrorMsg>()?.code, 'malformed');
      expect(c.closed, isFalse);
    });
  });

  test('room full is enforced', () {
    fakeAsync((fa) {
      final f = Fixture(fa, maxParticipants: 2);
      expect(f.join('dev-1').$2, isNotNull);
      expect(f.join('dev-2').$2, isNotNull);
      final (c, w) = f.join('dev-3');
      expect(w, isNull);
      expect(c.received.whereType<RejectMsg>().single.code, RejectCode.roomFull);
    });
  });

  test('heartbeat failure detection: suspect, then disconnected, then removed', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      final (c, _) = f.join('phone-1');
      // Silence: the raw client never sends heartbeats.
      fa.elapse(const Duration(seconds: 4));
      expect(f.coord.state.participant('phone-1')!.connection, ConnectionStatus.suspect);
      fa.elapse(const Duration(seconds: 5));
      expect(f.coord.state.participant('phone-1')!.connection, ConnectionStatus.disconnected);
      expect(c.closed, isTrue);
      fa.elapse(const Duration(seconds: 91));
      expect(f.coord.state.participant('phone-1'), isNull);
    });
  });

  test('lead time calculation', () {
    final d = computeLead(const SchedulerConfig(), const [
      ParticipantTiming(deviceId: 'a', rttP95Us: 10000, startLatencyUs: 50000, uncertaintyUs: 1000),
      ParticipantTiming(deviceId: 'b', rttP95Us: 200000, startLatencyUs: 80000, uncertaintyUs: 5000),
    ]);
    expect(d.dominatedBy, 'b');
    expect(d.leadUs, 300000 + 80000 + 5000 + 120000);
    final small = computeLead(const SchedulerConfig(), const []);
    expect(small.leadUs, 250000);
    expect(small.clampedToMin, isTrue);
  });
}
