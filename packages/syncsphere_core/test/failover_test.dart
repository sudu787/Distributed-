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

  test('succession order puts the preferred (original) host first when it is back', () {
    final s = _state([_p('b'), _p('c'), _p('orig')]).copyWith(preferredCoordinator: 'orig');
    expect(successionOrder(s).map((p) => p.deviceId), ['orig', 'b', 'c']);
    final gone = _state([_p('b'), _p('orig', c: ConnectionStatus.disconnected)]).copyWith(preferredCoordinator: 'orig');
    expect(successionOrder(gone).map((p) => p.deviceId), ['b']);
  });

  test('3 phones: host dies, next phone hosts, original host returns and gets the role back seamlessly', () {
    final r = SimulationRunner(const Scenario(
      name: 'failover-failback',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: Duration(seconds: 90),
      failover: true,
      actions: [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 20), KillCoordinatorAction()),
        ScheduledAction(Duration(seconds: 40), ReviveCoordinatorAction()),
        ScheduledAction(Duration(seconds: 75), SeekAction(Duration(minutes: 2))),
      ],
    )).run();
    expect(r.metrics['failedSessions'], isEmpty);
    final f = r.metrics['failover'] as Map<String, Object?>;
    expect(f['promoted'], 'device-1', reason: 'next phone takes over');
    expect(f['handbackDevice'], 'device-0', reason: 'original host gets the role back');
    expect(f['finalCoordinator'], 'device-0');
    expect(f['finalEpoch'], 3);
    final history = (f['history'] as List).cast<Map<String, Object?>>();
    expect(history.map((h) => h['epoch']), [1, 2, 3]);
    final backAt = history.last['trueMs'] as int;
    // Revived at 40 s, rejoins within about a second, then 10 s of stability.
    expect(backAt, inInclusiveRange(50000, 55000));
    final spread = f['spreadMs_15sAfterHandback'] as Map<String, Object?>;
    expect(spread['n'] as int, greaterThan(100));
    expect(spread['max'] as num, lessThan(50), reason: 'planned handback must not disturb alignment');
    // The seek after the handback goes through the original host again.
    expect((r.metrics['commandToAudibleLatencyMs'] as Map)['n'], 2);
  });

  test('flaky returning host: a link drop restarts the 10 s stability window (no flapping)', () {
    final r = SimulationRunner(const Scenario(
      name: 'failback-flaky',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: Duration(seconds: 100),
      failover: true,
      actions: [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 20), KillCoordinatorAction()),
        ScheduledAction(Duration(seconds: 40), ReviveCoordinatorAction()),
        // Back at ~41 s, but drops out for 6 s at 46 s (before 10 s of stability).
        ScheduledAction(Duration(seconds: 46), PartitionAction(0, Duration(seconds: 6))),
      ],
    )).run();
    expect(r.metrics['failedSessions'], isEmpty);
    final f = r.metrics['failover'] as Map<String, Object?>;
    final history = (f['history'] as List).cast<Map<String, Object?>>();
    expect(history.map((h) => h['epoch']), [1, 2, 3], reason: 'exactly one handback, no ping-pong');
    expect(f['finalCoordinator'], 'device-0');
    // Heal at 52 s, then a fresh 10 s window.
    expect(history.last['trueMs'] as int, greaterThanOrEqualTo(62000));
  });

  test('a guest cut off for 15 s does not make itself host (isolation hold-off)', () {
    final r = SimulationRunner(const Scenario(
      name: 'isolated-guest',
      participants: 4,
      network: NetworkCondition.wifiGood,
      duration: Duration(seconds: 60),
      failover: true,
      actions: [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 20), PartitionAction(3, Duration(seconds: 15))),
      ],
    )).run();
    final fd = r.metrics['failureDetection'] as Map<String, Object?>;
    expect(fd['hostChanges'], 0, reason: 'the cut-off phone must not start a second coordinator');
    expect(r.metrics['failover'], isNull);
    expect(r.metrics['failedSessions'], isEmpty);
    expect(fd['guestFailureDetectedAfterMs'], [inInclusiveRange(4000, 5000)], reason: 'phi detector on a steady link');
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
