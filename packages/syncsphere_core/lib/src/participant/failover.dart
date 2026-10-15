/// Coordinator failover by deterministic succession.
///
/// This is *not* consensus-based leader election. Every member derives the
/// same ordered candidate list from the last room state it received:
/// connected participants that offered to host (`canHost` with an
/// endpoint), in admission order, excluding the failed coordinator. When the
/// coordinator has been unreachable long enough:
///
///  * the first candidate promotes itself: it starts a coordinator with the
///    same room id and key, `epoch + 1`, and the last state with the
///    timeline translated into its own clock domain (generation preserved,
///    so devices that are already playing keep their audio running);
///  * everyone else reconnects to the first candidate, moving on to the next
///    one if it stays unreachable (and promoting itself if it is next).
///
/// Members always follow the highest coordinator epoch they have seen.
/// Limitation: under a network *partition* (as opposed to a crash) both
/// sides can end up with a coordinator; they do not merge automatically.
library;

import '../model/room_state.dart';
import '../protocol/auth.dart';
import '../time/clock_sync.dart';
import '../transport/transport.dart';

/// What a promoted device needs to start serving the room.
class PromotionRequest {
  /// Last known state, already translated to the promoted device's clock.
  final RoomState state;
  final int epoch;
  final RoomKey roomKey;
  final String joinKey;
  const PromotionRequest({
    required this.state,
    required this.epoch,
    required this.roomKey,
    required this.joinKey,
  });
}

/// Platform hooks for failover (implemented by the app and the simulator).
abstract class FailoverDelegate {
  /// Port this device would serve on if promoted (advertised at join).
  int get failoverPort;

  /// Starts a coordinator for [request] on this device and returns a
  /// connector this device's own session uses to join it.
  Future<Connector> promote(PromotionRequest request);

  /// Connector to another candidate's endpoint (`host:port`).
  Connector connectorFor(String endpoint);
}

class FailoverPolicy {
  /// How long after losing the coordinator link to start failover.
  final Duration failoverAfter;

  /// Connection attempts to a candidate before moving to the next one.
  final int attemptsPerCandidate;

  const FailoverPolicy({
    this.failoverAfter = const Duration(seconds: 2),
    this.attemptsPerCandidate = 3,
  });
}

/// Ordered failover candidates as seen in [s] (admission order).
List<ParticipantSummary> successionOrder(RoomState s) => [
      for (final p in s.participants)
        if (p.canHost &&
            p.endpoint != null &&
            p.deviceId != s.coordinatorId &&
            p.connection != ConnectionStatus.disconnected)
          p
    ];

/// Translates [s] for a coordinator running on the device whose clock
/// estimate of the *old* coordinator is [estimate]: coordinator-domain
/// anchors become local times. Pending segments are dropped (their
/// readiness barrier died with the old coordinator); generations continue.
RoomState translateForSuccessor(
  RoomState s, {
  required ClockEstimate estimate,
  required String newCoordinatorId,
  required int newEpoch,
}) {
  final tl = s.timeline;
  final translated = tl.status == PlaybackStatus.idle
      ? tl
      : tl.copyWith(anchorCoordUs: estimate.toLocal(tl.anchorCoordUs));
  return s.copyWith(
    coordinatorId: newCoordinatorId,
    coordinatorEpoch: newEpoch,
    timeline: translated,
    clearPending: true,
    clearCalibration: true,
  );
}
