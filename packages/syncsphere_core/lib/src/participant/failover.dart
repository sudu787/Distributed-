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

  /// When the link was declared dead because the coordinator went *silent*
  /// (no FIN/RST, e.g. Wi-Fi blip or power-save stall), failover also waits
  /// until nothing has been heard for this long. The failure detector can
  /// react within ~4 s on a steady link (reconnect attempts start at once),
  /// but promoting a successor is disruptive and there is no quorum to stop
  /// a briefly cut-off phone from promoting itself, so a short blip must not
  /// be enough. A closed connection without `bye` (the host app died) keeps
  /// the fast path ([failoverAfter]).
  final Duration silenceBeforeFailover;

  /// Before promoting *itself*, a device that is not first in the
  /// succession order and could not reach any successor ahead of it waits
  /// this much longer (on top of [silenceBeforeFailover]) and goes round
  /// again, coordinator first. If nobody ahead answers, the likeliest
  /// explanation is that *this* phone is cut off (a Wi-Fi blip), not that
  /// the host and every phone ahead died together; promoting would create a
  /// second coordinator that later pulls the whole room over to the phone
  /// that dropped out. It also avoids two successors promoting at once when
  /// the one ahead is merely a little slower.
  final Duration isolationHoldOff;

  const FailoverPolicy({
    this.failoverAfter = const Duration(seconds: 2),
    this.attemptsPerCandidate = 3,
    this.silenceBeforeFailover = const Duration(seconds: 8),
    this.isolationHoldOff = const Duration(seconds: 20),
  });
}

/// Ordered failover candidates as seen in [s]: the preferred coordinator
/// (original host) first if eligible, then admission order. Every member
/// derives the same order from the same replicated state, so no election
/// messages are needed (a Bully-style priority order).
List<ParticipantSummary> successionOrder(RoomState s) {
  final eligible = [
    for (final p in s.participants)
      if (p.canHost &&
          p.endpoint != null &&
          p.deviceId != s.coordinatorId &&
          p.connection != ConnectionStatus.disconnected)
        p
  ];
  final pref = s.preferredCoordinator;
  final i = pref == null ? -1 : eligible.indexWhere((p) => p.deviceId == pref);
  if (i > 0) eligible.insert(0, eligible.removeAt(i));
  return eligible;
}

/// When a successor hands the coordinator role back to the preferred device.
class HandbackPolicy {
  /// The preferred device must have been connected without interruption
  /// for this long (hysteresis against a flaky device bouncing the role).
  final Duration stableFor;

  /// Its reported clock uncertainty must be below this (when it reports).
  final Duration maxUncertainty;

  /// How long to wait for [HandoverAckMsg] before giving up.
  final Duration ackTimeout;

  /// Wait after a failed attempt; doubles on every failure (capped).
  final Duration backoff;
  final Duration maxBackoff;

  /// Grace between redirecting members and closing the old coordinator.
  final Duration closeDelay;

  const HandbackPolicy({
    this.stableFor = const Duration(seconds: 10),
    this.maxUncertainty = const Duration(milliseconds: 20),
    this.ackTimeout = const Duration(seconds: 5),
    this.backoff = const Duration(seconds: 60),
    this.maxBackoff = const Duration(minutes: 10),
    this.closeDelay = const Duration(milliseconds: 500),
  });
}

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
