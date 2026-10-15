import 'dart:convert';

import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

void main() {
  group('auth', () {
    final key = RoomKey.derive(roomId: 'room1', joinKey: 'ABCD-EFGH', iterations: 10);

    test('PBKDF2-HMAC-SHA256 matches RFC 7914 test vector', () {
      // RFC 7914 §11: P="passwd", S="salt", c=1, first 32 bytes.
      final out = pbkdf2Sha256(utf8.encode('passwd'), utf8.encode('salt'), 1);
      expect(
          out.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc');
    });

    test('join key normalisation is forgiving', () {
      expect(normalizeJoinKey('abcd-efgh'), 'ABCDEFGH');
      expect(normalizeJoinKey('o1l i'), '0111');
      final k2 = RoomKey.derive(roomId: 'room1', joinKey: 'abcd efgh', iterations: 10);
      expect(k2.clientProof('dev1', 'n1', 'n2'), key.clientProof('dev1', 'n1', 'n2'));
    });

    test('proofs depend on key, nonces and direction', () {
      final other = RoomKey.derive(roomId: 'room1', joinKey: 'WRONGKEY', iterations: 10);
      final p = key.clientProof('dev1', 'cn', 'sn');
      expect(other.clientProof('dev1', 'cn', 'sn'), isNot(p));
      expect(key.clientProof('dev1', 'cn', 'sn2'), isNot(p));
      expect(key.serverProof('dev1', 'cn', 'sn'), isNot(p));
    });

    test('generated join keys use the Crockford alphabet', () {
      final k = generateJoinKey(length: 26);
      expect(k, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$')));
    });

    test('transfer tokens verify only for the signed path', () {
      final keys = key.sessionKeys('dev1', 'cn', 'sn');
      final tok = signTransfer('sess', keys.transfer, '/tracks/abc', 12345);
      final parsed = TransferToken.parse(tok)!;
      expect(parsed.verify(keys.transfer, '/tracks/abc'), isTrue);
      expect(parsed.verify(keys.transfer, '/tracks/abd'), isFalse);
    });
  });

  group('FrameCodec', () {
    late FrameCodec a, b;
    final key = RoomKey.derive(roomId: 'r', joinKey: 'K', iterations: 1);
    final keys = key.sessionKeys('dev1', 'c', 's');

    setUp(() {
      a = FrameCodec();
      b = FrameCodec();
    });

    test('handshake frames round-trip unauthenticated', () {
      const hello = HelloMsg(
        deviceId: 'device-1',
        displayName: 'Pixel',
        platform: 'android',
        clientNonce: 'abcdefghijklmnopqrstuv',
        caps: DeviceCapabilities(rateControl: true, backend: 'test'),
      );
      final m = b.decode(a.encode(hello)) as HelloMsg;
      expect(m.deviceId, 'device-1');
      expect(m.caps.rateControl, isTrue);
    });

    test('non-handshake messages are refused before auth', () {
      expect(() => a.encode(const HeartbeatMsg(1)), throwsStateError);
      final forged = '-.${jsonEncode({'v': 1, 't': 'hb', 's': 1, 'b': {'t': 1}})}';
      expect(() => b.decode(forged),
          throwsA(isA<ProtocolException>().having((e) => e.code, 'code', 'unauthenticated')));
    });

    test('authenticated frames verify and reject tampering', () {
      a.activate(sendKey: keys.clientToServer, recvKey: keys.serverToClient);
      b.activate(sendKey: keys.serverToClient, recvKey: keys.clientToServer);
      final f = a.encode(const HeartbeatMsg(42));
      expect((b.decode(f) as HeartbeatMsg).senderTimeUs, 42);

      final f2 = a.encode(const HeartbeatMsg(43));
      final tampered = f2.replaceFirst('43', '44');
      expect(() => b.decode(tampered),
          throwsA(isA<ProtocolException>().having((e) => e.code, 'code', 'bad_mac')));
    });

    test('replayed frames are rejected', () {
      a.activate(sendKey: keys.clientToServer, recvKey: keys.serverToClient);
      b.activate(sendKey: keys.serverToClient, recvKey: keys.clientToServer);
      final f = a.encode(const HeartbeatMsg(1));
      b.decode(f);
      expect(() => b.decode(f),
          throwsA(isA<ProtocolException>().having((e) => e.code, 'code', 'replay')));
    });

    test('reflected frames fail (direction keys differ)', () {
      a.activate(sendKey: keys.clientToServer, recvKey: keys.serverToClient);
      final f = a.encode(const HeartbeatMsg(1));
      final a2 = FrameCodec()
        ..activate(sendKey: keys.clientToServer, recvKey: keys.serverToClient);
      expect(() => a2.decode(f), throwsA(isA<ProtocolException>()));
    });

    test('malformed input never throws anything but ProtocolException', () {
      final inputs = [
        '',
        '.',
        '-.',
        '-.{',
        '-.[]',
        '-.{"v":1}',
        '-.{"v":2,"t":"hello","s":1,"b":{}}',
        '-.{"v":1,"t":"hello","s":1,"b":{"pmin":"x"}}',
        '-.{"v":1,"t":"hello","s":0,"b":{}}',
        '-.{"v":1,"t":"hello","s":1.5,"b":{}}',
        '-.{"v":1,"t":"hello","s":1,"b":{"pmin":1,"pmax":1,"dev":"../../etc","name":"x","plat":"a","nonce":"abcdefghijklmnopqr","caps":{"rate":true,"backend":"x"}}}',
        'x' * 300000,
      ];
      for (final i in inputs) {
        final c = FrameCodec();
        expect(() => c.decode(i), throwsA(isA<ProtocolException>()), reason: i.length > 50 ? 'long' : i);
      }
    });

    test('unknown message types surface as UnknownMessage', () {
      final f = '-.${jsonEncode({'v': 1, 't': 'hello', 's': 1, 'b': {
            'pmin': 1,
            'pmax': 9,
            'dev': 'device-1',
            'name': 'n',
            'plat': 'p',
            'nonce': 'abcdefghijklmnopqr',
            'caps': {'rate': false, 'backend': 'b'},
            'futureField': 123,
          }})}';
      expect(FrameCodec().decode(f), isA<HelloMsg>());
      final c = FrameCodec()
        ..activate(sendKey: keys.clientToServer, recvKey: keys.serverToClient);
      final s = FrameCodec()
        ..activate(sendKey: keys.serverToClient, recvKey: keys.clientToServer);
      final frame = s.encode(const UnknownMessage('future.thing', {'x': 1}));
      expect(c.decode(frame), isA<UnknownMessage>());
    });

    test('control offsets are signed and bounded', () {
      final c = FrameCodec()
        ..activate(sendKey: keys.clientToServer, recvKey: keys.serverToClient);
      final s = FrameCodec()
        ..activate(sendKey: keys.serverToClient, recvKey: keys.clientToServer);
      final m = s.decode(c.encode(const ControlMsg(
          requestId: 1, action: ControlAction.setCalibration, baseVersion: 0, offsetUs: -250000))) as ControlMsg;
      expect(m.offsetUs, -250000);
      expect(m.action, ControlAction.setCalibration);
      expect(
          () => s.decode(c.encode(const ControlMsg(
              requestId: 2, action: ControlAction.setCalibration, baseVersion: 0, offsetUs: kMaxCalibrationUs + 1))),
          throwsA(isA<ProtocolException>()));
    });
  });

  group('RoomState', () {
    test('JSON round trip', () {
      final track = TrackInfo(
          id: 'a' * 64, title: 'Song', artist: 'Artist', durationUs: 180000000, sizeBytes: 1234);
      final s = RoomState(
        roomId: 'r1',
        roomName: 'Party',
        coordinatorId: 'host-1',
        version: 7,
        timeline: const PlaybackTimeline(
            generation: 3,
            trackId: null,
            status: PlaybackStatus.playing,
            anchorPositionUs: 1000,
            anchorCoordUs: 5000),
        pending: PendingSegment(generation: 4, trackId: 'a' * 64, positionUs: 0),
        playlist: [track],
        participants: const [
          ParticipantSummary(
              deviceId: 'host-1',
              displayName: 'Host',
              role: ParticipantRole.host,
              connection: ConnectionStatus.connected)
        ],
      );
      final back = RoomState.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
      expect(back.version, 7);
      expect(back.timeline.generation, 3);
      expect(back.pending!.generation, 4);
      expect(back.playlist.single.title, 'Song');
      expect(back.participants.single.role, ParticipantRole.host);
    });

    test('timeline expected position', () {
      const tl = PlaybackTimeline(
          generation: 1,
          trackId: 'x',
          status: PlaybackStatus.playing,
          anchorPositionUs: 10000000,
          anchorCoordUs: 2000000);
      expect(tl.expectedPositionAt(1000000), 10000000); // before start
      expect(tl.expectedPositionAt(3000000), 11000000);
      expect(tl.coordTimeForPosition(11000000), 3000000);
    });

    test('rejects invalid track ids', () {
      expect(
          () => TrackInfo.fromJson({'id': 'not-a-hash', 'title': 't', 'size': 1}),
          throwsA(isA<ProtocolException>()));
    });
  });

  group('SyncConfig', () {
    test('round trip and clamping of hostile values', () {
      const c = SyncConfig();
      final back = SyncConfig.fromJson(
          jsonDecode(jsonEncode(c.toJson())) as Map<String, Object?>);
      expect(back.drift.rateEnterThreshold, c.drift.rateEnterThreshold);
      final hostile = SyncConfig.fromJson({
        'drift': {'maxRateDelta': 50, 'rateEnterThresholdUs': 1000, 'rateExitThresholdUs': 5000},
        'membership': {'maxParticipants': 1e9},
      });
      expect(hostile.drift.maxRateDelta, 0.25);
      expect(hostile.drift.rateExitThreshold < hostile.drift.rateEnterThreshold, isTrue);
      expect(hostile.membership.maxParticipants, 256);
    });
  });
}
