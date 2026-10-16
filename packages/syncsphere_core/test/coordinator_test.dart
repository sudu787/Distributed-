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
  // Test helper; the connection is torn down with the fake network.
  // ignore: cancel_subscriptions
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

  Fixture(this.fa,
      {ParticipantRole defaultRole = ParticipantRole.listener,
      int maxParticipants = 16,
      String? preferredCoordinator,
      int epoch = 1}) {
    coord = RoomCoordinator(
      options: CoordinatorOptions(
        roomId: 'room-1',
        roomName: 'Test',
        coordinatorId: 'host-device',
        joinKey: kKey,
        kdfIterations: 5,
        defaultRole: defaultRole,
        config: SyncConfig(membership: MembershipConfig(maxParticipants: maxParticipants)),
        preferredCoordinator: preferredCoordinator,
        coordinatorEpoch: epoch,
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
  (RawClient, WelcomeMsg?) join(String deviceId,
      {String key = kKey, DeviceCapabilities caps = const DeviceCapabilities(rateControl: true, backend: 'test')}) {
    final c = raw(deviceId);
    const nonce = 'client-nonce-123456';
    c.send(HelloMsg(
      deviceId: deviceId,
      displayName: deviceId,
      platform: 'test',
      clientNonce: nonce,
      caps: caps,
    ));
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

  test('members who control can add songs the coordinator has; listeners cannot', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      final uploaded = <String>{};
      f.coord.trackAvailable = uploaded.contains;
      final (host, _) = f.join('host-device');
      final (p, _) = f.join('phone-1');
      const song = TrackInfo(
          id: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', title: 'C', sizeBytes: 9, durationUs: 1000000);
      uploaded.add(song.id);
      p.send(const ControlMsg(requestId: 1, action: ControlAction.addTrack, baseVersion: 0, info: song));
      fa.elapse(const Duration(milliseconds: 10));
      expect(p.last<ControlAckMsg>()!.error, ControlError.unauthorized);

      host.send(const ControlMsg(
          requestId: 1, action: ControlAction.setRole, baseVersion: 0, targetDevice: 'phone-1', role: ParticipantRole.controller));
      fa.elapse(const Duration(milliseconds: 10));
      // A song the coordinator does not have is refused (nobody could download it).
      const missing = TrackInfo(
          id: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd', title: 'D', sizeBytes: 9);
      p.send(const ControlMsg(requestId: 2, action: ControlAction.addTrack, baseVersion: 0, info: missing));
      p.send(const ControlMsg(requestId: 3, action: ControlAction.addTrack, baseVersion: 0, info: song));
      fa.elapse(const Duration(milliseconds: 10));
      final acks = p.received.whereType<ControlAckMsg>().toList();
      expect(acks[1].error, ControlError.invalid);
      expect(acks[2].accepted, isTrue);
      final added = f.coord.state.trackById(song.id)!;
      expect(added.hostServes, isTrue);
      expect(f.coord.state.playlist.length, tracks.length + 1);
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

  test('repeat: next wraps only with repeat all', () {
    fakeAsync((fa) {
      final f = Fixture(fa, defaultRole: ParticipantRole.controller);
      final (a, _) = f.join('host-device');
      void ctl(ControlMsg Function(int v) m) {
        a.send(m(f.coord.state.version));
        fa.elapse(const Duration(milliseconds: 10));
      }

      ctl((v) => ControlMsg(requestId: 1, action: ControlAction.setTrack, baseVersion: v, trackId: tracks[1].id));
      ctl((v) => ControlMsg(requestId: 2, action: ControlAction.next, baseVersion: v));
      expect(a.last<ControlAckMsg>()!.error, ControlError.nothingToPlay);
      ctl((v) => ControlMsg(requestId: 3, action: ControlAction.setRepeat, baseVersion: v, mode: 'all'));
      expect(f.coord.state.repeat, PlaylistRepeat.all);
      ctl((v) => ControlMsg(requestId: 4, action: ControlAction.next, baseVersion: v));
      expect(a.last<ControlAckMsg>()!.accepted, isTrue);
      expect(f.coord.state.pending!.trackId, tracks[0].id);
      ctl((v) => ControlMsg(requestId: 5, action: ControlAction.setRepeat, baseVersion: v, mode: 'bogus'));
      expect(a.last<ControlAckMsg>()!.error, ControlError.invalid);
    });
  });

  test('shuffle visits every track once per cycle', () {
    fakeAsync((fa) {
      final many = [
        for (var i = 0; i < 6; i++)
          TrackInfo(id: i.toRadixString(16) * 64, title: 'T$i', sizeBytes: 1, durationUs: 60000000)
      ];
      final f = Fixture(fa, defaultRole: ParticipantRole.controller);
      f.coord.setPlaylist(many);
      final (a, _) = f.join('host-device');
      void ctl(ControlAction act, {double? value, String? mode, String? track}) {
        a.send(ControlMsg(
            requestId: 1, action: act, baseVersion: f.coord.state.version, value: value, mode: mode, trackId: track));
        fa.elapse(const Duration(milliseconds: 10));
      }

      ctl(ControlAction.setTrack, track: many[0].id);
      ctl(ControlAction.setShuffle, value: 1);
      expect(f.coord.state.shuffle, isTrue);
      final seen = <String>{f.coord.state.pending!.trackId};
      for (var i = 0; i < 5; i++) {
        ctl(ControlAction.next);
        seen.add(f.coord.state.pending!.trackId);
      }
      expect(seen.length, 6, reason: 'no repeats within one shuffle cycle');
      ctl(ControlAction.next);
      expect(a.last<ControlAckMsg>()!.error, ControlError.nothingToPlay);
    });
  });

  test('repeat one replays the same track at its end', () {
    fakeAsync((fa) {
      final short = [TrackInfo(id: 'c' * 64, title: 'Short', sizeBytes: 1, durationUs: 15000000)];
      final f = Fixture(fa, defaultRole: ParticipantRole.controller);
      f.coord.setPlaylist(short);
      final (a, _) = f.join('host-device');
      a.send(ControlMsg(requestId: 1, action: ControlAction.setRepeat, baseVersion: 0, mode: 'one'));
      a.send(ControlMsg(requestId: 2, action: ControlAction.play, baseVersion: f.coord.state.version));
      fa.elapse(const Duration(milliseconds: 10));
      final p = f.coord.state.pending!;
      a.send(ReadyMsg(generation: p.generation, trackId: p.trackId, ok: true));
      fa.elapse(const Duration(milliseconds: 10));
      final g = f.coord.state.timeline.generation;
      expect(f.coord.state.timeline.isPlaying, isTrue);
      // Keep the link alive and let the track approach its end.
      for (var i = 0; i < 10; i++) {
        a.send(HeartbeatMsg(i));
        fa.elapse(const Duration(seconds: 1));
      }
      final next = f.coord.state.pending;
      expect(next, isNotNull);
      expect(next!.trackId, short.single.id);
      expect(next.generation, greaterThan(g));
    });
  });

  test('channel roles: own device always, others only with control rights', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      final (host, _) = f.join('host-device');
      final (p, _) = f.join('phone-1');
      p.send(const ControlMsg(requestId: 1, action: ControlAction.setChannelRole, baseVersion: 0, mode: 'left'));
      p.send(const ControlMsg(
          requestId: 2, action: ControlAction.setChannelRole, baseVersion: 0, mode: 'right', targetDevice: 'host-device'));
      fa.elapse(const Duration(milliseconds: 10));
      final acks = p.received.whereType<ControlAckMsg>().toList();
      expect(acks[0].accepted, isTrue);
      expect(acks[1].error, ControlError.unauthorized);
      expect(f.coord.state.participant('phone-1')!.channel, ChannelRole.left);
      host.send(const ControlMsg(
          requestId: 3, action: ControlAction.setChannelRole, baseVersion: 0, mode: 'mono', targetDevice: 'phone-1'));
      fa.elapse(const Duration(milliseconds: 10));
      expect(f.coord.state.participant('phone-1')!.channel, ChannelRole.mono);
    });
  });

  test('manual calibration: own device always, others only with control rights', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      final (host, _) = f.join('host-device');
      final (p, _) = f.join('phone-1');
      p.send(const ControlMsg(requestId: 1, action: ControlAction.setCalibration, baseVersion: 0, offsetUs: -42000));
      p.send(const ControlMsg(
          requestId: 2, action: ControlAction.setCalibration, baseVersion: 0, offsetUs: 5000, targetDevice: 'host-device'));
      p.send(const ControlMsg(requestId: 3, action: ControlAction.setCalibration, baseVersion: 0));
      fa.elapse(const Duration(milliseconds: 10));
      final acks = p.received.whereType<ControlAckMsg>().toList();
      expect(acks[0].accepted, isTrue);
      expect(acks[1].error, ControlError.unauthorized);
      expect(acks[2].error, ControlError.invalid);
      expect(f.coord.state.participant('phone-1')!.calibrationUs, -42000);
      host.send(const ControlMsg(
          requestId: 4, action: ControlAction.setCalibration, baseVersion: 0, offsetUs: 7000, targetDevice: 'phone-1'));
      fa.elapse(const Duration(milliseconds: 10));
      expect(f.coord.state.participant('phone-1')!.calibrationUs, 7000);
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
