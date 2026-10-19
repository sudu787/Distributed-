/// Editing the shared playlist: move, remove (including the playing song)
/// and the published "up next".
library;

import 'package:fake_async/fake_async.dart';
import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

import 'coordinator_test.dart' show Fixture, RawClient;

final _three = [
  TrackInfo(id: 'a' * 64, title: 'A', sizeBytes: 1, durationUs: 60000000),
  TrackInfo(id: 'b' * 64, title: 'B', sizeBytes: 1, durationUs: 60000000),
  TrackInfo(id: 'c' * 64, title: 'C', sizeBytes: 1, durationUs: 60000000),
];

List<String> _titles(Fixture f) => [for (final t in f.coord.state.playlist) t.title];

void main() {
  late int rid;
  void send(Fixture f, FakeAsync fa, RawClient c, ControlAction a, {String? track, int? to, String? mode, double? value}) {
    c.send(ControlMsg(
        requestId: ++rid, action: a, baseVersion: f.coord.state.version, trackId: track, toIndex: to, mode: mode, value: value));
    fa.elapse(const Duration(milliseconds: 10));
  }

  void startPlaying(Fixture f, FakeAsync fa, RawClient host, String track) {
    send(f, fa, host, ControlAction.setTrack, track: track);
    final p = f.coord.state.pending!;
    host.send(ReadyMsg(generation: p.generation, trackId: p.trackId, ok: true));
    fa.elapse(const Duration(seconds: 1));
    expect(f.coord.state.timeline.isPlaying, isTrue);
  }

  setUp(() => rid = 0);

  test('move: reorders for controllers only; the move message round-trips', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      f.coord.setPlaylist(_three);
      final (host, _) = f.join('host-device');
      final (guest, _) = f.join('phone-1');
      send(f, fa, host, ControlAction.moveTrack, track: 'c' * 64, to: 0);
      expect(_titles(f), ['C', 'A', 'B']);
      send(f, fa, host, ControlAction.moveTrack, track: 'c' * 64, to: 99);
      expect(_titles(f), ['A', 'B', 'C'], reason: 'index clamped to the end');
      send(f, fa, guest, ControlAction.moveTrack, track: 'a' * 64, to: 2);
      expect(guest.last<ControlAckMsg>()!.error, ControlError.unauthorized);
      send(f, fa, host, ControlAction.moveTrack, track: 'd' * 64, to: 0);
      expect(host.last<ControlAckMsg>()!.error, ControlError.unknownTrack);

      const sent = ControlMsg(requestId: 1, action: ControlAction.moveTrack, baseVersion: 3, trackId: 'x', toIndex: 4);
      final m = ControlMsg.read(Reader(sent.toBody(), 'ctl'));
      expect(m.toIndex, 4);
      expect(m.action, ControlAction.moveTrack);
    });
  });

  test('remove: a queued song goes; the playing song moves on to the next; the last one stops', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      f.coord.setPlaylist(_three);
      final (host, _) = f.join('host-device');
      startPlaying(f, fa, host, 'a' * 64);
      expect(f.coord.state.upNext, 'b' * 64);

      send(f, fa, host, ControlAction.removeTrack, track: 'b' * 64);
      expect(_titles(f), ['A', 'C']);
      expect(f.coord.state.timeline.trackId, 'a' * 64, reason: 'the playing song keeps playing');
      expect(f.coord.state.upNext, 'c' * 64);

      send(f, fa, host, ControlAction.removeTrack, track: 'a' * 64);
      expect(_titles(f), ['C']);
      expect(f.coord.state.pending?.trackId, 'c' * 64, reason: 'playback moves on to the next song');

      final p = f.coord.state.pending!;
      host.send(ReadyMsg(generation: p.generation, trackId: p.trackId, ok: true));
      fa.elapse(const Duration(seconds: 1));
      send(f, fa, host, ControlAction.removeTrack, track: 'c' * 64);
      expect(f.coord.state.playlist, isEmpty);
      expect(f.coord.state.timeline.status, PlaybackStatus.idle);
      expect(f.coord.state.pending, isNull);
    });
  });

  test('removing the song that auto-advance is preparing keeps the current one playing', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      f.coord.setPlaylist([
        TrackInfo(id: 'a' * 64, title: 'A', sizeBytes: 1, durationUs: 12000000),
        ..._three.skip(1),
      ]);
      final (host, _) = f.join('host-device');
      startPlaying(f, fa, host, 'a' * 64);
      final playingGen = f.coord.state.timeline.generation;
      for (var i = 0; i < 6 && f.coord.state.pending == null; i++) {
        host.send(HeartbeatMsg(i));
        fa.elapse(const Duration(seconds: 1));
      }
      expect(f.coord.state.pending?.trackId, 'b' * 64, reason: 'B is being prepared');
      send(f, fa, host, ControlAction.removeTrack, track: 'b' * 64);
      expect(f.coord.state.timeline.generation, playingGen, reason: 'A was not cut off');
      expect(f.coord.state.timeline.isPlaying, isTrue);
      host.send(HeartbeatMsg(99));
      fa.elapse(const Duration(seconds: 1));
      expect(f.coord.state.pending?.trackId, 'c' * 64, reason: 'C is prepared instead');
    });
  });

  test('up next follows repeat and "play next" while shuffling', () {
    fakeAsync((fa) {
      final f = Fixture(fa);
      f.coord.setPlaylist(_three);
      final (host, _) = f.join('host-device');
      startPlaying(f, fa, host, 'a' * 64);
      send(f, fa, host, ControlAction.setRepeat, mode: 'one');
      expect(f.coord.state.upNext, 'a' * 64);
      send(f, fa, host, ControlAction.setRepeat, mode: 'off');
      send(f, fa, host, ControlAction.moveTrack, track: 'c' * 64, to: 0);
      expect(f.coord.state.upNext, 'b' * 64, reason: 'C is now before A');
      send(f, fa, host, ControlAction.setShuffle, value: 1);
      // "Play next": right after the current song, also in the shuffle order.
      final cur = f.coord.state.indexOfTrack('a' * 64);
      send(f, fa, host, ControlAction.moveTrack, track: 'c' * 64, to: cur);
      expect(_titles(f), ['A', 'C', 'B']);
      expect(f.coord.state.upNext, 'c' * 64);
      expect(RoomState.fromJson(f.coord.state.toJson()).upNext, 'c' * 64);
    });
  });
}
