/// Coordinator failover by succession (SIMULATED end-to-end + unit tests).
@Timeout(Duration(minutes: 3))
library;

import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

RoomState _state(List<ParticipantSummary> parts) => RoomState(
      roomId: 'r',
      roomName: 'R',
      coordinatorId: 'host',
      coordinatorEpoch: 3,
      version: 10,
      timeline: const PlaybackTimeline(
          generation: 7, trackId: 'x', status: PlaybackStatus.playing, anchorPositionUs: 5000000, anchorCoordUs: 1000000000),
      pending: const PendingSegment(generation: 8, trackId: 'x', positionUs: 0),
      participants: parts,
    );

ParticipantSummary _p(String id, {bool canHost = true, String? ep = 'h:1', ConnectionStatus c = ConnectionStatus.connected}) =>
    ParticipantSummary(deviceId: id, displayName: id, role: ParticipantRole.controller, connection: c, canHost: canHost, endpoint: ep);

void main() {
  test('succession order: admission order, eligible and connected only, never the coordinator', () {
    final s = _state([
      _p('host'),
      _p('a', canHost: false),
      _p('b'),
      _p('c', ep: null),
      _p('d', c: ConnectionStatus.disconnected),
      _p('e', c: ConnectionStatus.suspect),
    ]);
    expect(successionOrder(s).map((p) => p.deviceId), ['b', 'e']);
  });

  test('timeline translation keeps generation, converts anchor, drops pending', () {
    const est = ClockEstimate(
      referenceLocalMicros: 0,
      offsetMicros: 400000000, // old coordinator is 400 s ahead of us
      skewPpm: 0,
      uncertaintyMicros: 1000,
      skewUncertaintyPpm: 0,
      samplesInWindow: 10,
      samplesUsed: 10,
      minDelayMicros: 2000,
      newestSampleLocalMicros: 0,
      method: 'test',
    );
    final t = translateForSuccessor(_state([_p('host'), _p('b')]), estimate: est, newCoordinatorId: 'b', newEpoch: 4);
    expect(t.coordinatorId, 'b');
    expect(t.coordinatorEpoch, 4);
    expect(t.timeline.generation, 7);
    expect(t.timeline.anchorCoordUs, 1000000000 - 400000000);
    expect(t.timeline.anchorPositionUs, 5000000);
    expect(t.pending, isNull);
  });

  test('host dies: successor takes over, playback continues, everyone rejoins', () {
    final r = SimulationRunner(const Scenario(
      name: 'failover',
      participants: 4,
      network: NetworkCondition.wifiTypical,
      duration: Duration(seconds: 90),
      failover: true,
      actions: [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 30), KillCoordinatorAction()),
        ScheduledAction(Duration(seconds: 70), SeekAction(Duration(minutes: 2))),
      ],
    )).run();
    expect(r.metrics['failedSessions'], isEmpty);
    final f = r.metrics['failover'] as Map<String, Object?>;
    expect(f['promoted'], 'device-1');
    expect(f['finalEpoch'], 2);
    expect(f['promotedAfterKillMs'] as int, lessThan(10000));
    final spread = f['spreadMs_15sAfterPromotion'] as Map<String, Object?>;
    expect(spread['n'] as int, greaterThan(100));
    expect(spread['max'] as num, lessThan(50), reason: 'handover must not disturb alignment');
    // The seek after failover goes through the new coordinator.
    expect((r.metrics['commandToAudibleLatencyMs'] as Map)['n'], 2);
  });

  test('chained failover: the successor dies too and the next candidate takes over', () {
    final r = SimulationRunner(const Scenario(
      name: 'failover-chain',
      participants: 4,
      network: NetworkCondition.wifiGood,
      duration: Duration(seconds: 100),
      failover: true,
      actions: [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 25), KillCoordinatorAction()),
        ScheduledAction(Duration(seconds: 55), KillCoordinatorAction()),
      ],
    )).run();
    expect(r.metrics['failedSessions'], isEmpty);
    final f = r.metrics['failover'] as Map<String, Object?>;
    expect(f['finalEpoch'], 3);
    expect(r.metrics['killedDevices'], ['device-0', 'device-1']);
    // The second takeover must be as quick as the first (regression: stale
    // failover state used to skip the first candidate and add ~10 s).
    expect(f['promotedAfterKillMs'] as int, lessThan(6000));
  });

  test('without failover enabled the room reports that it must be recreated', () {
    final r = SimulationRunner(const Scenario(
      name: 'no-failover',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: Duration(minutes: 6),
      actions: [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 20), KillCoordinatorAction()),
      ],
    )).run();
    expect((r.metrics['failedSessions'] as List).length, 2);
    expect(r.metrics['failover'], isNull);
  });
}
