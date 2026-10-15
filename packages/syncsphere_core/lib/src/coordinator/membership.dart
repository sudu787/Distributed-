/// Membership manager: who is in the room, how healthy their link is, and
/// what each participant last told us about its sync state.
///
/// Failure detection is timeout-based on *any* inbound traffic (heartbeats,
/// clock probes and reports all count):
///
///     connected --(no traffic ≥ suspectAfter)--> suspect
///     suspect   --(traffic)-------------------> connected
///     suspect   --(no traffic ≥ failAfter)----> disconnected (link closed)
///     disconnected --(re-auth within grace)---> connected (same slot)
///     disconnected --(grace expired)----------> removed
library;

import '../config/sync_config.dart';
import '../model/room_state.dart';
import '../protocol/auth.dart';
import '../protocol/messages.dart';

class Member {
  final String deviceId;
  String displayName;
  ParticipantRole role;
  ConnectionStatus connection = ConnectionStatus.connected;
  double volume = 1.0;
  DeviceCapabilities caps;
  String sessionId;
  SessionKeys keys;
  int lastSeenUs;
  final int joinedAtUs;
  int? disconnectedAtUs;

  /// Increments every time this member authenticates a new link; lets the
  /// coordinator ignore traffic from a superseded link.
  int linkEpoch = 0;

  // Sync telemetry (latest values reported by the participant).
  SyncReportMsg? lastReport;
  int? lastReportAtUs;
  int startLatencyUs = 0;
  int rttP95Us = 0;
  int uncertaintyUs = 0;
  final Map<String, TrackAvailability> availability = {};

  // Readiness for the coordinator's current pending segment.
  int? readyGeneration;
  bool readyOk = false;
  String? readyError;

  Member({
    required this.deviceId,
    required this.displayName,
    required this.role,
    required this.caps,
    required this.sessionId,
    required this.keys,
    required this.lastSeenUs,
  }) : joinedAtUs = lastSeenUs;

  bool get isConnected => connection != ConnectionStatus.disconnected;

  ParticipantSummary summary(String? currentTrackId) => ParticipantSummary(
        deviceId: deviceId,
        displayName: displayName,
        role: role,
        connection: connection,
        volume: volume,
        currentTrack: currentTrackId == null
            ? TrackAvailability.unknown
            : (availability[currentTrackId] ?? TrackAvailability.unknown),
        canHost: caps.canHost,
      );
}

/// Outcome of [MembershipManager.sweep].
class SweepResult {
  final List<Member> becameSuspect;
  final List<Member> recovered;
  final List<Member> failed;
  final List<Member> removed;
  const SweepResult(this.becameSuspect, this.recovered, this.failed, this.removed);
  bool get changed =>
      becameSuspect.isNotEmpty || recovered.isNotEmpty || failed.isNotEmpty || removed.isNotEmpty;
}

class MembershipManager {
  final MembershipConfig config;
  final Map<String, Member> _members = {};

  MembershipManager(this.config);

  Iterable<Member> get all => _members.values;
  Iterable<Member> get connected => _members.values.where((m) => m.isConnected);
  int get connectedCount => connected.length;
  Member? byDevice(String id) => _members[id];

  Member? bySession(String sessionId) {
    for (final m in _members.values) {
      if (m.sessionId == sessionId) return m;
    }
    return null;
  }

  /// True if a *new* device can be admitted.
  bool get hasCapacity => _members.length < config.maxParticipants;

  /// Admits a device, or re-admits it into its existing slot (reconnect).
  /// Returns null when the room is full.
  Member? admit({
    required String deviceId,
    required String displayName,
    required ParticipantRole defaultRole,
    required DeviceCapabilities caps,
    required String sessionId,
    required SessionKeys keys,
    required int nowUs,
  }) {
    final existing = _members[deviceId];
    if (existing != null) {
      existing
        ..displayName = displayName
        ..caps = caps
        ..sessionId = sessionId
        ..keys = keys
        ..connection = ConnectionStatus.connected
        ..disconnectedAtUs = null
        ..lastSeenUs = nowUs
        ..linkEpoch += 1
        ..readyGeneration = null
        ..lastReport = null
        ..lastReportAtUs = null;
      return existing;
    }
    if (!hasCapacity) return null;
    final m = Member(
      deviceId: deviceId,
      displayName: displayName,
      role: defaultRole,
      caps: caps,
      sessionId: sessionId,
      keys: keys,
      lastSeenUs: nowUs,
    )..linkEpoch = 1;
    _members[deviceId] = m;
    return m;
  }

  /// Records inbound traffic. Returns true if this recovered a suspect member.
  bool touch(Member m, int nowUs) {
    m.lastSeenUs = nowUs;
    if (m.connection == ConnectionStatus.suspect) {
      m.connection = ConnectionStatus.connected;
      return true;
    }
    return false;
  }

  void markDisconnected(Member m, int nowUs) {
    if (m.connection == ConnectionStatus.disconnected) return;
    m.connection = ConnectionStatus.disconnected;
    m.disconnectedAtUs = nowUs;
    m.readyGeneration = null;
  }

  void remove(String deviceId) => _members.remove(deviceId);

  SweepResult sweep(int nowUs) {
    final suspect = <Member>[], recovered = <Member>[], failed = <Member>[], removed = <Member>[];
    for (final m in _members.values.toList()) {
      final silent = nowUs - m.lastSeenUs;
      switch (m.connection) {
        case ConnectionStatus.connected:
          if (silent >= config.failAfter.inMicroseconds) {
            failed.add(m);
          } else if (silent >= config.suspectAfter.inMicroseconds) {
            m.connection = ConnectionStatus.suspect;
            suspect.add(m);
          }
        case ConnectionStatus.suspect:
          if (silent >= config.failAfter.inMicroseconds) failed.add(m);
        case ConnectionStatus.disconnected:
          final since = m.disconnectedAtUs ?? nowUs;
          if (m.role != ParticipantRole.host &&
              nowUs - since >= config.reconnectGrace.inMicroseconds) {
            removed.add(m);
            _members.remove(m.deviceId);
          }
      }
    }
    for (final m in failed) {
      markDisconnected(m, nowUs);
    }
    return SweepResult(suspect, recovered, failed, removed);
  }
}
