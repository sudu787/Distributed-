/// The Room Coordinator: single authority for room membership, playlist and
/// the playback timeline.
///
/// Consistency model: all state changes are serialised through this object
/// (one Dart isolate, no concurrency) and published as full snapshots tagged
/// with a monotonically increasing `version`. Participants apply a snapshot
/// only if it is newer than what they have. Control requests carry the
/// version their sender based them on and are rejected when they could
/// overwrite a newer, conflicting intent (see [_handleControl]).
///
/// The coordinator never tells devices to "play now". It publishes a
/// timeline anchored at a future coordinator time and every participant
/// renders that timeline in its own clock domain.
library;

import 'dart:async';
import 'dart:math';


import '../config/sync_config.dart';
import '../calibration/calibration_analysis.dart';
import '../model/calibration_plan.dart';
import '../model/room_state.dart';
import '../observability/event_log.dart';
import '../protocol/auth.dart';
import '../protocol/codec.dart';
import '../protocol/messages.dart';
import '../protocol/reader.dart';
import '../time/clock.dart';
import '../transport/transport.dart';
import 'lead_time.dart';
import 'membership.dart';

class CoordinatorOptions {
  final String roomId;
  final String roomName;

  /// Device id of the host. That device joins with the `host` role.
  final String coordinatorId;
  final String joinKey;
  final int kdfIterations;
  final SyncConfig config;
  final ParticipantRole defaultRole;
  final DistributionMode distribution;
  final ProtocolLimits limits;
  final int coordinatorEpoch;

  /// Max unauthenticated connections held at once.
  final int maxPendingHandshakes;

  /// Pre-derived room key. PBKDF2 is deliberately slow; apps derive it on a
  /// background isolate and pass it here to keep the UI responsive.
  final RoomKey? roomKey;

  const CoordinatorOptions({
    required this.roomId,
    required this.roomName,
    required this.coordinatorId,
    required this.joinKey,
    this.kdfIterations = kDefaultKdfIterations,
    this.config = const SyncConfig(),
    this.defaultRole = ParticipantRole.listener,
    this.distribution = DistributionMode.auto,
    this.limits = const ProtocolLimits(),
    this.coordinatorEpoch = 1,
    this.maxPendingHandshakes = 32,
    this.roomKey,
  });
}

/// Result of a control request.
class ControlOutcome {
  final bool accepted;
  final String? error;
  const ControlOutcome.ok()
      : accepted = true,
        error = null;
  const ControlOutcome.fail(this.error) : accepted = false;
}

enum _Hs { awaitHello, awaitAuth, active, closed }

class _PeerLink {
  final MessageConnection conn;
  final FrameCodec codec;
  _Hs hs = _Hs.awaitHello;
  HelloMsg? hello;
  String? serverNonce;
  Member? member;
  int memberEpoch = 0;
  Timer? handshakeTimer;
  // Cancelled in RoomCoordinator._closeLink.
  // ignore: cancel_subscriptions
  StreamSubscription<String>? sub;
  final List<int> malformedAt = [];

  _PeerLink(this.conn, ProtocolLimits limits) : codec = FrameCodec(limits: limits);

  String get remoteHost {
    final a = conn.remoteAddress;
    final i = a.lastIndexOf(':');
    return i > 0 ? a.substring(0, i) : a;
  }
}

class _Barrier {
  final int generation;
  final Set<String> waitingFor;
  final int startedAtUs;
  final int deadlineUs;

  /// Earliest coordinator time the segment may start (track transitions
  /// start exactly when the previous track ends).
  final int? notBeforeUs;
  _Barrier(this.generation, this.waitingFor, this.startedAtUs, this.deadlineUs, this.notBeforeUs);
}

class RoomCoordinator {
  final CoordinatorOptions options;
  final MonotonicClock clock;
  final EventLog log;
  final RoomKey _key;
  final String instanceId;
  late final MembershipManager _members;

  late RoomState _state;
  int _timelineVersion = 0;
  final Set<_PeerLink> _links = {};
  final Map<String, List<int>> _authFailures = {};
  _Barrier? _barrier;
  int? _autoAdvancedGeneration;

  final StreamController<RoomState> _stateCtl = StreamController.broadcast();
  final StreamController<DiagnosticsMsg> _diagCtl = StreamController.broadcast();
  final List<StreamSubscription<MessageConnection>> _acceptorSubs = [];
  Timer? _heartbeatTimer;
  Timer? _tickTimer;
  Timer? _diagTimer;
  bool _publishScheduled = false;
  bool _closed = false;
  DiagnosticsMsg _lastDiagnostics = const DiagnosticsMsg([]);

  /// Start-time measurements reported by participants (observability).
  final List<Map<String, Object?>> startReports = [];

  /// Roles from the state this coordinator was restored from (failover),
  /// re-applied when those devices rejoin.
  final Map<String, ParticipantRole> _restoredRoles = {};

  final Random _random;
  List<String> _shuffleOrder = const [];

  RoomCoordinator({
    required this.options,
    required this.clock,
    EventLog? log,
    RoomState? restoredState,
    String? instanceId,
    Random? random,
  })  : log = log ?? EventLog(clock: clock, source: 'coordinator'),
        _random = random ?? Random(),
        instanceId = instanceId ?? newId(9),
        _key = options.roomKey ??
            RoomKey.derive(
                roomId: options.roomId,
                joinKey: options.joinKey,
                iterations: options.kdfIterations) {
    if (_key.roomId != options.roomId) {
      throw ArgumentError('roomKey was derived for room ${_key.roomId}, not ${options.roomId}');
    }
    _members = MembershipManager(options.config.membership);
    _state = restoredState?.copyWith(
          coordinatorId: options.coordinatorId,
          coordinatorEpoch: options.coordinatorEpoch,
          version: restoredState.version + 1,
          participants: const [],
        ) ??
        RoomState(
          roomId: options.roomId,
          roomName: options.roomName,
          coordinatorId: options.coordinatorId,
          coordinatorEpoch: options.coordinatorEpoch,
          version: 1,
          timeline: const PlaybackTimeline.idle(),
          distribution: options.distribution,
        );
    _timelineVersion = _state.version;
    if (restoredState != null) {
      for (final p in restoredState.participants) {
        // The previous host does not keep host rights on the new coordinator.
        _restoredRoles[p.deviceId] =
            p.role == ParticipantRole.host ? ParticipantRole.controller : p.role;
      }
    }
  }

  RoomState get state => _state;
  Stream<RoomState> get stateStream => _stateCtl.stream;
  Stream<DiagnosticsMsg> get diagnosticsStream => _diagCtl.stream;
  DiagnosticsMsg get diagnostics => _lastDiagnostics;
  SyncConfig get config => options.config;
  Iterable<Member> get members => _members.all;

  // ------------------------------------------------------------ lifecycle

  void start() {
    final m = options.config.membership;
    _heartbeatTimer = Timer.periodic(m.heartbeatInterval, (_) => _heartbeat());
    _tickTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    _diagTimer = Timer.periodic(const Duration(seconds: 1), (_) => _publishDiagnostics());
    log.info('room.start', 'room ${options.roomId} "${options.roomName}" started',
        {'epoch': options.coordinatorEpoch, 'instance': instanceId});
  }

  void serve(ConnectionAcceptor acceptor) {
    _acceptorSubs.add(acceptor.connections.listen(accept));
  }

  /// Takes ownership of a freshly accepted connection.
  void accept(MessageConnection conn) {
    if (_closed) {
      conn.close('room closed');
      return;
    }
    final pending = _links.where((l) => l.hs != _Hs.active).length;
    if (pending >= options.maxPendingHandshakes) {
      log.warn('security.limit', 'too many pending handshakes; dropping ${conn.remoteAddress}');
      conn.close('busy');
      return;
    }
    final link = _PeerLink(conn, options.limits);
    _links.add(link);
    link.handshakeTimer = Timer(options.config.membership.handshakeTimeout, () {
      if (link.hs != _Hs.active) {
        _reject(link, RejectCode.timeout, 'handshake timed out');
      }
    });
    link.sub = conn.incoming.listen(
      (frame) => _onFrame(link, frame),
      onDone: () => _onLinkClosed(link),
      onError: (Object e) {
        log.warn('link.error', 'link error from ${conn.remoteAddress}: $e');
        _onLinkClosed(link);
      },
    );
  }

  Future<void> close({String reason = 'room closed'}) async {
    if (_closed) return;
    _closed = true;
    _heartbeatTimer?.cancel();
    _tickTimer?.cancel();
    _diagTimer?.cancel();
    _calibrationTimer?.cancel();
    for (final s in _acceptorSubs) {
      await s.cancel();
    }
    for (final l in _links.toList()) {
      if (l.hs == _Hs.active) _send(l, ByeMsg(reason));
      l.handshakeTimer?.cancel();
      await l.sub?.cancel();
      await l.conn.close(reason);
    }
    _links.clear();
    log.info('room.close', 'room closed: $reason');
    await _stateCtl.close();
    await _diagCtl.close();
  }

  /// Stops abruptly without notifying members (no `bye`), as if the
  /// process had crashed. Used by failover tests and the simulator.
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    _heartbeatTimer?.cancel();
    _tickTimer?.cancel();
    _diagTimer?.cancel();
    _calibrationTimer?.cancel();
    for (final s in _acceptorSubs) {
      await s.cancel();
    }
    for (final l in _links.toList()) {
      l.hs = _Hs.closed;
      l.handshakeTimer?.cancel();
      await l.sub?.cancel();
      await l.conn.close('aborted');
    }
    _links.clear();
    log.warn('room.abort', 'coordinator aborted');
    await _stateCtl.close();
    await _diagCtl.close();
  }

  // --------------------------------------------------------- host-local API

  void setPlaylist(List<TrackInfo> tracks) {
    if (tracks.length > options.limits.maxPlaylistLength) {
      throw ArgumentError('playlist longer than ${options.limits.maxPlaylistLength}');
    }
    _mutate(_state.copyWith(playlist: List.unmodifiable(tracks)), timeline: true);
  }

  void addTrack(TrackInfo t) {
    if (_state.trackById(t.id) != null) return;
    setPlaylist([..._state.playlist, t]);
  }

  void removeTrack(String trackId) {
    if (_state.timeline.trackId == trackId && _state.timeline.isPlaying) {
      throw StateError('cannot remove the playing track');
    }
    setPlaylist(_state.playlist.where((t) => t.id != trackId).toList());
  }

  void setDistribution(DistributionMode mode) =>
      _mutate(_state.copyWith(distribution: mode));

  /// Session keys for authorising LAN downloads (null if unknown/offline).
  SessionKeys? transferKeysForSession(String sessionId) {
    final m = _members.bySession(sessionId);
    if (m == null || !m.isConnected) return null;
    return m.keys;
  }

  /// Applies a control request on behalf of [deviceId] (used by the
  /// protocol handler; exposed for tests and the CLI).
  ControlOutcome control(String deviceId, ControlMsg c) {
    final m = _members.byDevice(deviceId);
    if (m == null || !m.isConnected) {
      return const ControlOutcome.fail(ControlError.notConnected);
    }
    return _handleControl(m, c);
  }

  // ------------------------------------------------------------- framing

  void _onFrame(_PeerLink link, String frame) {
    final t2 = clock.nowMicros(); // receive timestamp, before any parsing
    if (link.hs == _Hs.closed) return;
    final Message msg;
    try {
      msg = link.codec.decode(frame);
    } on ProtocolException catch (e) {
      _onProtocolError(link, e);
      return;
    }
    final m = link.member;
    if (m != null) {
      if (link.memberEpoch != m.linkEpoch) {
        // Superseded by a newer authenticated link for the same device.
        _closeLink(link, 'superseded');
        return;
      }
      if (_members.touch(m, t2)) {
        log.info('member.recovered', '${m.displayName} recovered', {'device': m.deviceId});
        _mutate(_state);
      }
    }
    switch (link.hs) {
      case _Hs.awaitHello:
        if (msg is HelloMsg) {
          _onHello(link, msg);
        } else {
          _reject(link, RejectCode.protocolError, 'expected hello');
        }
      case _Hs.awaitAuth:
        if (msg is AuthMsg) {
          _onAuth(link, msg);
        } else {
          _reject(link, RejectCode.protocolError, 'expected auth');
        }
      case _Hs.active:
        _onActiveMessage(link, link.member!, msg, t2);
      case _Hs.closed:
        break;
    }
  }

  void _onProtocolError(_PeerLink link, ProtocolException e) {
    if (link.hs != _Hs.active) {
      log.warn('security.handshake', 'bad handshake frame from ${link.conn.remoteAddress}: $e');
      _reject(link, RejectCode.protocolError, e.code);
      return;
    }
    // Integrity failures on an authenticated channel are never tolerated.
    if (e.code == 'bad_mac' || e.code == 'replay' || e.code == 'unauthenticated') {
      log.error('security.integrity', 'integrity failure from ${link.member?.deviceId}: $e');
      _closeLink(link, 'integrity failure');
      return;
    }
    final now = clock.nowMicros();
    link.malformedAt
      ..add(now)
      ..removeWhere((t) => now - t > 60000000);
    log.warn('protocol.malformed', 'malformed message from ${link.member?.deviceId}: $e');
    _send(link, ErrorMsg(e.code, e.message));
    if (link.malformedAt.length > 20) {
      _closeLink(link, 'too many malformed messages');
    }
  }

  // ----------------------------------------------------------- handshake

  bool _isRateLimited(String host) {
    final now = clock.nowMicros();
    final window = options.config.membership.authWindow.inMicroseconds;
    final list = _authFailures[host];
    if (list == null) return false;
    list.removeWhere((t) => now - t > window);
    if (list.isEmpty) _authFailures.remove(host);
    return list.length >= options.config.membership.maxAuthFailures;
  }

  void _onHello(_PeerLink link, HelloMsg h) {
    if (_isRateLimited(link.remoteHost)) {
      _reject(link, RejectCode.rateLimited, 'too many failed attempts; retry later');
      return;
    }
    final lo = max(h.protoMin, kProtocolMin), hi = min(h.protoMax, kProtocolMax);
    if (lo > hi) {
      _reject(link, RejectCode.unsupportedVersion,
          'server speaks $kProtocolMin..$kProtocolMax, client ${h.protoMin}..${h.protoMax}');
      return;
    }
    if (h.roomId != null && h.roomId != options.roomId) {
      _reject(link, RejectCode.wrongRoom, 'this coordinator hosts ${options.roomId}');
      return;
    }
    if (_members.byDevice(h.deviceId) == null && !_members.hasCapacity) {
      _reject(link, RejectCode.roomFull, 'room is full');
      return;
    }
    link
      ..hello = h
      ..serverNonce = newNonce()
      ..hs = _Hs.awaitAuth;
    _send(
        link,
        ChallengeMsg(
          protocol: hi,
          roomId: options.roomId,
          roomName: _state.roomName,
          coordinatorId: options.coordinatorId,
          coordinatorEpoch: options.coordinatorEpoch,
          instance: instanceId,
          serverNonce: link.serverNonce!,
          kdfIterations: _key.iterations,
        ));
  }

  void _onAuth(_PeerLink link, AuthMsg a) {
    final h = link.hello!;
    final expected = _key.clientProof(h.deviceId, h.clientNonce, link.serverNonce!);
    if (!constantTimeEquals(expected, a.proof)) {
      _authFailures.putIfAbsent(link.remoteHost, () => []).add(clock.nowMicros());
      log.warn('security.auth', 'authentication failed for ${h.deviceId} from ${link.remoteHost}');
      _reject(link, RejectCode.authFailed, 'wrong join key');
      return;
    }
    final now = clock.nowMicros();
    final keys = _key.sessionKeys(h.deviceId, h.clientNonce, link.serverNonce!);
    final isHost = h.deviceId == options.coordinatorId;
    final existing = _members.byDevice(h.deviceId);
    final m = _members.admit(
      deviceId: h.deviceId,
      displayName: h.displayName,
      defaultRole: isHost ? ParticipantRole.host : options.defaultRole,
      caps: h.caps,
      sessionId: newId(),
      keys: keys,
      nowUs: now,
    );
    if (m == null) {
      _reject(link, RejectCode.roomFull, 'room is full');
      return;
    }
    if (isHost) {
      m.role = ParticipantRole.host;
    } else if (existing == null && _restoredRoles.containsKey(m.deviceId)) {
      m.role = _restoredRoles[m.deviceId]!;
    }
    final fport = h.caps.failoverPort;
    m.endpoint = fport == null ? null : '${link.remoteHost}:$fport';
    // The room becomes the source of truth for a device's calibration once
    // it joined; reconnects keep the room's value.
    if (existing == null) m.calibrationUs = h.caps.calibrationUs;
    // Close any older link of this device (e.g. after a silent failure).
    for (final other in _links.toList()) {
      if (!identical(other, link) && other.member?.deviceId == m.deviceId) {
        _closeLink(other, 'superseded by new session');
      }
    }
    link.handshakeTimer?.cancel();
    link
      ..member = m
      ..memberEpoch = m.linkEpoch;
    link.codec.activate(sendKey: keys.serverToClient, recvKey: keys.clientToServer);
    log.info(existing == null ? 'member.join' : 'member.rejoin',
        '${m.displayName} ${existing == null ? 'joined' : 'reconnected'}',
        {'device': m.deviceId, 'role': m.role.name, 'backend': h.caps.backend});
    // Bump the version and broadcast the new roster to everyone else first
    // (this link is not active yet), so `welcome` is the first message the
    // newcomer receives and carries the newest state.
    _mutate(_state);
    _flushPublish();
    link.hs = _Hs.active;
    _send(
        link,
        WelcomeMsg(
          sessionId: m.sessionId,
          role: m.role,
          serverProof: _key.serverProof(h.deviceId, h.clientNonce, link.serverNonce!),
          config: options.config,
          state: _state,
        ));
    _checkBarrier();
  }

  void _reject(_PeerLink link, String code, String reason) {
    if (link.hs == _Hs.closed) return;
    try {
      if (!link.codec.isAuthenticated) {
        link.conn.send(link.codec.encode(RejectMsg(code, reason)));
      }
    } catch (_) {
      // Encoding a reject cannot fail for valid codes; ignore send failures
      // on a link we are closing anyway.
    }
    _closeLink(link, 'rejected: $code');
  }

  void _closeLink(_PeerLink link, String reason) {
    if (link.hs == _Hs.closed) return;
    link.hs = _Hs.closed;
    link.handshakeTimer?.cancel();
    link.sub?.cancel();
    link.conn.close(reason);
    _links.remove(link);
    final m = link.member;
    if (m != null && m.linkEpoch == link.memberEpoch && m.isConnected) {
      _members.markDisconnected(m, clock.nowMicros());
      log.info('member.disconnect', '${m.displayName} disconnected: $reason', {'device': m.deviceId});
      _mutate(_state);
      _checkBarrier();
    }
  }

  void _onLinkClosed(_PeerLink link) => _closeLink(link, 'connection closed');

  // --------------------------------------------------------- steady state

  void _onActiveMessage(_PeerLink link, Member m, Message msg, int t2) {
    switch (msg) {
      case HeartbeatMsg():
        break;
      case ClockRequestMsg(:final id, :final t1):
        final t3 = clock.nowMicros();
        _send(link, ClockResponseMsg(id, t1, t2, t3));
      case ReadyMsg():
        _onReady(m, msg);
      case ControlMsg():
        final out = _handleControl(m, msg);
        _flushPublish(); // state before ack so the sender sees the effect
        _send(
            link,
            ControlAckMsg(
                requestId: msg.requestId,
                accepted: out.accepted,
                error: out.error,
                version: _state.version));
      case SyncReportMsg():
        m
          ..lastReport = msg
          ..lastReportAtUs = t2
          ..rttP95Us = msg.rttP95Us
          ..uncertaintyUs = msg.uncertaintyUs;
        final cal = _state.calibration;
        if (cal != null && _state.isCalibrationTrack(_state.timeline.trackId) &&
            msg.generation == _state.timeline.generation) {
          (_calibrationReports[m.deviceId] ??= []).add((msg.coordTimeUs, msg.errorUs));
        }
      case CalibrationResultMsg():
        _onCalibrationResult(m, msg);
      case PlaybackEventMsg():
        _onPlaybackEvent(m, msg);
      case AvailabilityMsg():
        var changed = false;
        for (final e in msg.tracks) {
          if (_state.trackById(e.trackId) == null) continue;
          if (m.availability[e.trackId] != e.availability) {
            m.availability[e.trackId] = e.availability;
            changed = true;
          }
        }
        if (changed) _mutate(_state);
      case ByeMsg(:final reason):
        log.info('member.leave', '${m.displayName} left: $reason', {'device': m.deviceId});
        _closeLink(link, 'left');
        if (m.role != ParticipantRole.host) _members.remove(m.deviceId);
        _mutate(_state);
      case UnknownMessage(:final type):
        log.debug('protocol.unknown', 'ignoring unknown message type "$type" from ${m.deviceId}');
      default:
        log.warn('protocol.unexpected', 'unexpected ${msg.type} from ${m.deviceId}');
    }
  }

  void _onPlaybackEvent(Member m, PlaybackEventMsg e) {
    final level = e.kind == PlaybackEventKind.error ? EventLevel.warn : EventLevel.info;
    log.add(level, 'participant.${e.kind.name}', '${m.displayName}: ${e.kind.name}${e.detail == null ? '' : ' (${e.detail})'}',
        {'device': m.deviceId, 'gen': e.generation, ...e.data});
    if (e.kind == PlaybackEventKind.started) {
      startReports.add({'device': m.deviceId, 'gen': e.generation, ...e.data});
      if (startReports.length > 500) startReports.removeAt(0);
    }
  }

  // ------------------------------------------------------------ control

  ControlOutcome _handleControl(Member m, ControlMsg c) {
    const ok = ControlOutcome.ok();
    final tl = _state.timeline;
    bool stale() => c.baseVersion < _timelineVersion;

    switch (c.action) {
      case ControlAction.deviceVolume:
        final target = c.targetDevice ?? m.deviceId;
        if (target != m.deviceId && !m.role.canControl) {
          return const ControlOutcome.fail(ControlError.unauthorized);
        }
        final t = _members.byDevice(target);
        if (t == null || c.value == null) {
          return const ControlOutcome.fail(ControlError.invalid);
        }
        t.volume = c.value!;
        _mutate(_state);
        return ok;
      case ControlAction.masterVolume:
        if (!m.role.canControl) return const ControlOutcome.fail(ControlError.unauthorized);
        if (c.value == null) return const ControlOutcome.fail(ControlError.invalid);
        _mutate(_state.copyWith(masterVolume: c.value));
        return ok;
      case ControlAction.setRole:
        if (m.role != ParticipantRole.host) {
          return const ControlOutcome.fail(ControlError.unauthorized);
        }
        final t = c.targetDevice == null ? null : _members.byDevice(c.targetDevice!);
        if (t == null ||
            c.role == null ||
            c.role == ParticipantRole.host ||
            t.role == ParticipantRole.host) {
          return const ControlOutcome.fail(ControlError.invalid);
        }
        t.role = c.role!;
        log.info('member.role', '${t.displayName} is now ${t.role.name}');
        _mutate(_state);
        return ok;
      case ControlAction.setChannelRole:
        final target = c.targetDevice ?? m.deviceId;
        if (target != m.deviceId && !m.role.canControl) {
          return const ControlOutcome.fail(ControlError.unauthorized);
        }
        final t = _members.byDevice(target);
        final role = _parseEnum(ChannelRole.values, c.mode);
        if (t == null || role == null) return const ControlOutcome.fail(ControlError.invalid);
        t.channel = role;
        log.info('member.channel', '${t.displayName} plays ${role.name}');
        _mutate(_state);
        return ok;
      case ControlAction.setCalibration:
        final target = c.targetDevice ?? m.deviceId;
        if (target != m.deviceId && !m.role.canControl) {
          return const ControlOutcome.fail(ControlError.unauthorized);
        }
        final t = _members.byDevice(target);
        if (t == null || c.offsetUs == null) return const ControlOutcome.fail(ControlError.invalid);
        t.calibrationUs = c.offsetUs;
        log.info('member.calibration', '${t.displayName} output calibration ${c.offsetUs! ~/ 1000} ms (manual)');
        _mutate(_state);
        return ok;
      default:
        break;
    }

    if (!m.role.canControl) return const ControlOutcome.fail(ControlError.unauthorized);

    if (_state.calibration != null &&
        const {
          ControlAction.play,
          ControlAction.pause,
          ControlAction.seek,
          ControlAction.setTrack,
          ControlAction.next,
          ControlAction.previous,
          ControlAction.calibrate,
        }.contains(c.action)) {
      return const ControlOutcome.fail(ControlError.busy);
    }

    switch (c.action) {
      case ControlAction.calibrate:
        return _startCalibration(m);

      case ControlAction.play:
        if (tl.isPlaying || (_state.pending?.autoPlay ?? false)) return ok; // idempotent
        if (tl.status == PlaybackStatus.paused && tl.trackId != null) {
          _requestSegment(tl.trackId!, tl.anchorPositionUs);
          return ok;
        }
        final track = tl.trackId ?? (_state.playlist.isEmpty ? null : _state.playlist.first.id);
        if (track == null) return const ControlOutcome.fail(ControlError.nothingToPlay);
        _requestSegment(track, tl.trackId == null ? 0 : tl.anchorPositionUs);
        return ok;

      case ControlAction.pause:
        _pause();
        return ok;

      case ControlAction.seek:
        if (stale()) return const ControlOutcome.fail(ControlError.staleVersion);
        final track = _state.pending?.trackId ?? tl.trackId;
        if (track == null || c.positionUs == null) {
          return const ControlOutcome.fail(ControlError.invalid);
        }
        final pos = _clampPosition(track, c.positionUs!);
        if (tl.isPlaying || (_state.pending?.autoPlay ?? false)) {
          _requestSegment(track, pos);
        } else {
          _setPaused(track, pos);
        }
        return ok;

      case ControlAction.setTrack:
        if (stale()) return const ControlOutcome.fail(ControlError.staleVersion);
        final id = c.trackId;
        if (id == null || _state.trackById(id) == null) {
          return const ControlOutcome.fail(ControlError.unknownTrack);
        }
        _requestSegment(id, _clampPosition(id, c.positionUs ?? 0));
        return ok;

      case ControlAction.next:
      case ControlAction.previous:
        if (stale()) return const ControlOutcome.fail(ControlError.staleVersion);
        final cur = _state.pending?.trackId ?? tl.trackId;
        final playing = tl.isPlaying || (_state.pending?.autoPlay ?? false);
        final wrap = _state.repeat == PlaylistRepeat.all;
        String? id;
        if (c.action == ControlAction.next) {
          id = _neighbor(cur, 1, wrap: wrap);
        } else {
          final pos = tl.expectedPositionAt(clock.nowMicros());
          id = (playing && pos > 3000000) ? cur : (_neighbor(cur, -1, wrap: wrap) ?? cur);
        }
        if (id == null) return const ControlOutcome.fail(ControlError.nothingToPlay);
        if (playing) {
          _requestSegment(id, 0);
        } else {
          _setPaused(id, 0);
        }
        return ok;

      case ControlAction.setRepeat:
        final mode = _parseEnum(PlaylistRepeat.values, c.mode);
        if (mode == null) return const ControlOutcome.fail(ControlError.invalid);
        _mutate(_state.copyWith(repeat: mode));
        return ok;

      case ControlAction.setShuffle:
        if (c.value == null) return const ControlOutcome.fail(ControlError.invalid);
        final on = c.value! >= 0.5;
        if (on) _reshuffle(keepFirst: _state.pending?.trackId ?? tl.trackId);
        _mutate(_state.copyWith(shuffle: on));
        return ok;

      default:
        return const ControlOutcome.fail(ControlError.invalid);
    }
  }

  // ------------------------------------------------------ calibration

  int _calibrationSeq = 0;
  final Map<String, List<(int, int)>> _calibrationReports = {};
  Timer? _calibrationTimer;
  (String, int)? _preCalibration;

  ControlOutcome _startCalibration(Member listener) {
    if (!listener.caps.microphone) {
      log.warn('calibration.reject', '${listener.displayName} has no microphone for calibration');
      return const ControlOutcome.fail(ControlError.invalid);
    }
    final order = [
      for (final m in _members.all)
        if (m.connection == ConnectionStatus.connected) m.deviceId
    ];
    if (order.isEmpty) return const ControlOutcome.fail(ControlError.invalid);
    final tl = _state.timeline;
    final now = clock.nowMicros();
    final curTrack = _state.pending?.trackId ?? tl.trackId;
    _preCalibration = curTrack == null || _state.isCalibrationTrack(curTrack)
        ? null
        : (curTrack, _state.pending?.positionUs ?? tl.expectedPositionAt(now));
    final plan = CalibrationPlan(id: ++_calibrationSeq, listener: listener.deviceId, order: order);
    _calibrationReports.clear();
    log.info('calibration.start',
        'calibrating ${order.length} device(s) to ${listener.displayName}\'s position (plan ${plan.id})',
        {'devices': order.length, 'durationMs': plan.durationUs ~/ 1000});
    _mutate(_state.copyWith(calibration: plan));
    _requestSegment(plan.trackId, 0);
    final sched = options.config.scheduler;
    _calibrationTimer?.cancel();
    _calibrationTimer = Timer(
        Duration(microseconds: plan.durationUs) + sched.readinessTimeout + sched.maxLead + const Duration(seconds: 20),
        () {
      log.warn('calibration.timeout', 'no calibration result from the listener; cancelled');
      _endCalibration();
    });
    return const ControlOutcome.ok();
  }

  void _onCalibrationResult(Member from, CalibrationResultMsg r) {
    final plan = _state.calibration;
    if (plan == null || r.calibrationId != plan.id || from.deviceId != plan.listener) {
      log.debug('calibration.stale', 'ignoring calibration result ${r.calibrationId} from ${from.deviceId}');
      return;
    }
    final tl = _state.timeline;
    if (r.error != null) {
      log.warn('calibration.failed', 'calibration failed on the listener: ${r.error}');
    } else if (!_state.isCalibrationTrack(tl.trackId) || !tl.isPlaying) {
      log.warn('calibration.failed', 'calibration result arrived without a calibration segment');
    } else {
      final corrections = combineCalibration(
        plan: plan,
        arrivalsBySlot: {
          for (final e in r.arrivals.entries)
            if (plan.order.contains(e.key)) e.key: e.value
        },
        softwareErrorAt: (id, slot) =>
            _softwareErrorAt(id, tl.coordTimeForPosition(plan.slotPositionUs(slot))),
      );
      corrections.forEach((id, corr) {
        final m = _members.byDevice(id);
        if (m == null) return;
        m.calibrationUs = ((m.calibrationUs ?? 0) + corr).clamp(-kMaxCalibrationUs, kMaxCalibrationUs);
      });
      log.info('calibration.done',
          'calibration applied to ${corrections.length} device(s)${r.undetected.isEmpty ? '' : '; not heard: ${r.undetected.join(', ')}'}',
          {for (final e in corrections.entries) e.key: e.value});
    }
    _endCalibration();
  }

  /// A device's own software-estimated playback error at coordinator time
  /// [t], interpolated from its sync reports during the calibration (0 when
  /// unknown, i.e. assumed converged).
  int _softwareErrorAt(String deviceId, int t) {
    final reps = _calibrationReports[deviceId];
    if (reps == null || reps.isEmpty) return 0;
    reps.sort((a, b) => a.$1.compareTo(b.$1));
    if (t <= reps.first.$1) return reps.first.$2;
    if (t >= reps.last.$1) return reps.last.$2;
    for (var i = 1; i < reps.length; i++) {
      final (ta, ea) = reps[i - 1];
      final (tb, eb) = reps[i];
      if (t <= tb) return tb == ta ? eb : (ea + (eb - ea) * (t - ta) / (tb - ta)).round();
    }
    return reps.last.$2;
  }

  void _endCalibration() {
    _calibrationTimer?.cancel();
    _calibrationTimer = null;
    if (_state.calibration == null) return;
    _barrier = null;
    final gen = _nextGeneration();
    final pre = _preCalibration;
    _preCalibration = null;
    final tl = pre == null
        ? PlaybackTimeline(
            generation: gen,
            trackId: null,
            status: PlaybackStatus.idle,
            anchorPositionUs: 0,
            anchorCoordUs: clock.nowMicros())
        : PlaybackTimeline(
            generation: gen,
            trackId: pre.$1,
            status: PlaybackStatus.paused,
            anchorPositionUs: pre.$2,
            anchorCoordUs: clock.nowMicros());
    _mutate(_state.copyWith(timeline: tl, clearPending: true, clearCalibration: true), timeline: true);
  }

  /// Play order: playlist order, or the shuffle order when shuffling.
  List<String> _order() {
    final ids = [for (final t in _state.playlist) t.id];
    if (!_state.shuffle) return ids;
    final present = ids.toSet();
    final order = [for (final id in _shuffleOrder) if (present.contains(id)) id];
    final missing = ids.where((id) => !order.contains(id)).toList()..shuffle(_random);
    order.addAll(missing);
    _shuffleOrder = order;
    return order;
  }

  void _reshuffle({String? keepFirst}) {
    final ids = [for (final t in _state.playlist) t.id]..shuffle(_random);
    if (keepFirst != null && ids.remove(keepFirst)) ids.insert(0, keepFirst);
    _shuffleOrder = ids;
  }

  /// Track [delta] steps from [current] in play order (null at the ends
  /// unless [wrap]). With no current track, the first track.
  String? _neighbor(String? current, int delta, {required bool wrap}) {
    final order = _order();
    if (order.isEmpty) return null;
    final i = current == null ? -1 : order.indexOf(current);
    if (i < 0) return delta > 0 ? order.first : null;
    var j = i + delta;
    if (j < 0 || j >= order.length) {
      if (!wrap) return null;
      j = j % order.length;
      if (j < 0) j += order.length;
    }
    return order[j];
  }

  static T? _parseEnum<T extends Enum>(List<T> values, String? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  int _clampPosition(String trackId, int pos) {
    final dur = _state.trackById(trackId)?.durationUs;
    if (dur == null || dur <= 0) return max(0, pos);
    return pos.clamp(0, max(0, dur - 1000));
  }

  int _nextGeneration() =>
      max(_state.timeline.generation, _state.pending?.generation ?? 0) + 1;

  /// Asks participants to prepare a new segment; promotion to a scheduled
  /// start happens when the readiness barrier completes.
  void _requestSegment(String trackId, int positionUs, {int? notBeforeUs}) {
    final gen = _nextGeneration();
    final pending = PendingSegment(generation: gen, trackId: trackId, positionUs: positionUs);
    final now = clock.nowMicros();
    final waiting = _members.connected
        .where((m) => m.connection == ConnectionStatus.connected)
        .map((m) => m.deviceId)
        .toSet();
    _barrier = _Barrier(gen, waiting, now,
        now + options.config.scheduler.readinessTimeout.inMicroseconds, notBeforeUs);
    log.info('schedule.prepare', 'prepare g$gen track=${_short(trackId)} at ${positionUs ~/ 1000} ms',
        {'gen': gen, 'waiting': waiting.length});
    _mutate(_state.copyWith(pending: pending), timeline: true);
    _checkBarrier();
  }

  void _setPaused(String trackId, int positionUs) {
    _barrier = null;
    final gen = _nextGeneration();
    _mutate(
        _state.copyWith(
          timeline: PlaybackTimeline(
              generation: gen,
              trackId: trackId,
              status: PlaybackStatus.paused,
              anchorPositionUs: positionUs,
              anchorCoordUs: clock.nowMicros()),
          clearPending: true,
        ),
        timeline: true);
  }

  void _pause() {
    final tl = _state.timeline;
    final now = clock.nowMicros();
    if (tl.isPlaying) {
      _barrier = null;
      final lead = computeLead(
          options.config.scheduler,
          _members.connected.map((m) => ParticipantTiming(
              deviceId: m.deviceId,
              rttP95Us: m.rttP95Us,
              startLatencyUs: 0,
              uncertaintyUs: m.uncertaintyUs)));
      // Never pause before the segment has even started.
      final at = max(now + lead.leadUs, tl.anchorCoordUs);
      final pos = tl.expectedPositionAt(at);
      final gen = _nextGeneration();
      log.info('schedule.pause', 'pause g$gen at +${lead.leadUs ~/ 1000} ms, pos ${pos ~/ 1000} ms',
          lead.toJson());
      _mutate(
          _state.copyWith(
            timeline: PlaybackTimeline(
                generation: gen,
                trackId: tl.trackId,
                status: PlaybackStatus.paused,
                anchorPositionUs: pos,
                anchorCoordUs: at),
            clearPending: true,
          ),
          timeline: true);
    } else if (_state.pending != null) {
      final p = _state.pending!;
      _setPaused(p.trackId, p.positionUs);
    }
  }

  void _onReady(Member m, ReadyMsg r) {
    m
      ..startLatencyUs = r.startLatencyUs
      ..rttP95Us = r.rttP95Us
      ..uncertaintyUs = r.uncertaintyUs;
    final pending = _state.pending;
    if (pending == null || r.generation != pending.generation) {
      log.debug('schedule.ready.stale', 'ignoring ready for g${r.generation} from ${m.deviceId}');
      return;
    }
    m
      ..readyGeneration = r.generation
      ..readyOk = r.ok
      ..readyError = r.error;
    if (!r.ok) {
      log.warn('schedule.notReady', '${m.displayName} cannot play g${r.generation}: ${r.error}',
          {'device': m.deviceId});
    }
    _checkBarrier();
  }

  void _checkBarrier() {
    final b = _barrier;
    final pending = _state.pending;
    if (b == null || pending == null || pending.generation != b.generation) return;
    final now = clock.nowMicros();
    final waiting = b.waitingFor
        .map(_members.byDevice)
        .whereType<Member>()
        .where((m) => m.isConnected)
        .toList();
    final responded = waiting.where((m) => m.readyGeneration == b.generation).toList();
    final allResponded = responded.length == waiting.length;
    if (!allResponded && now < b.deadlineUs) return;

    final ready = _members.connected
        .where((m) => m.readyGeneration == b.generation && m.readyOk)
        .toList();
    _barrier = null;
    if (ready.isEmpty) {
      log.error('schedule.abort', 'no participant could prepare g${b.generation}; aborting',
          {'gen': b.generation, 'timedOut': !allResponded});
      _mutate(_state.copyWith(clearPending: true), timeline: true);
      return;
    }
    if (!allResponded) {
      final late = waiting.where((m) => m.readyGeneration != b.generation).map((m) => m.deviceId);
      log.warn('schedule.timeout', 'readiness timeout; starting without ${late.join(', ')} (they will join late)');
    }
    if (!pending.autoPlay) {
      _setPaused(pending.trackId, pending.positionUs);
      return;
    }
    final lead = computeLead(
        options.config.scheduler,
        ready.map((m) => ParticipantTiming(
            deviceId: m.deviceId,
            rttP95Us: m.rttP95Us,
            startLatencyUs: m.startLatencyUs,
            uncertaintyUs: m.uncertaintyUs)));
    var startAt = now + lead.leadUs;
    if (b.notBeforeUs != null && b.notBeforeUs! > startAt) startAt = b.notBeforeUs!;
    log.info('schedule.start',
        'start g${pending.generation} at +${(startAt - now) ~/ 1000} ms (${ready.length} ready, barrier ${(now - b.startedAtUs) ~/ 1000} ms)',
        {'gen': pending.generation, ...lead.toJson(), 'barrierUs': now - b.startedAtUs});
    _mutate(
        _state.copyWith(
          timeline: PlaybackTimeline(
              generation: pending.generation,
              trackId: pending.trackId,
              status: PlaybackStatus.playing,
              anchorPositionUs: pending.positionUs,
              anchorCoordUs: startAt),
          clearPending: true,
        ),
        timeline: true);
  }

  // -------------------------------------------------------------- timers

  void _heartbeat() {
    final now = clock.nowMicros();
    for (final l in _links.toList()) {
      if (l.hs == _Hs.active) _send(l, HeartbeatMsg(now));
    }
    final sweep = _members.sweep(now);
    for (final m in sweep.becameSuspect) {
      log.warn('member.suspect', '${m.displayName} is unresponsive', {'device': m.deviceId});
    }
    for (final m in sweep.failed) {
      log.warn('member.failed', '${m.displayName} timed out', {'device': m.deviceId});
      for (final l in _links.toList()) {
        if (l.member?.deviceId == m.deviceId) _closeLink(l, 'heartbeat timeout');
      }
    }
    for (final m in sweep.removed) {
      log.info('member.removed', '${m.displayName} removed after reconnect grace', {'device': m.deviceId});
    }
    if (sweep.changed) {
      _mutate(_state);
      _checkBarrier();
    }
  }

  void _tick() {
    _checkBarrier();
    _autoAdvance();
  }

  /// Prepares the next track shortly before the current one ends and starts
  /// it exactly at the end of the current one.
  void _autoAdvance() {
    final tl = _state.timeline;
    if (!tl.isPlaying || tl.trackId == null || _state.pending != null || _state.calibration != null) return;
    if (_autoAdvancedGeneration == tl.generation) return;
    final dur = _state.trackById(tl.trackId)?.durationUs;
    if (dur == null || dur <= 0) return;
    final now = clock.nowMicros();
    final endAt = tl.coordTimeForPosition(dur);
    final prepareWindow = options.config.scheduler.readinessTimeout.inMicroseconds +
        options.config.scheduler.maxLead.inMicroseconds;
    if (now < endAt - prepareWindow) return;
    _autoAdvancedGeneration = tl.generation;
    final next = _state.repeat == PlaylistRepeat.one
        ? tl.trackId
        : _neighbor(tl.trackId, 1, wrap: _state.repeat == PlaylistRepeat.all);
    if (next != null) {
      log.info('schedule.advance', 'track ending; preparing ${next == tl.trackId ? 'repeat' : 'next track'}');
      _requestSegment(next, 0, notBeforeUs: endAt);
    } else {
      // End of playlist: stop at the end of the track.
      Timer(Duration(microseconds: max(0, endAt - now)), () {
        if (_state.timeline.generation == tl.generation && _state.pending == null) {
          _setPaused(tl.trackId!, 0);
        }
      });
    }
  }

  void _publishDiagnostics() {
    final now = clock.nowMicros();
    final parts = <ParticipantDiagnostics>[];
    final errs = <int>[];
    for (final m in _members.all) {
      final r = m.lastReport;
      final age = m.lastReportAtUs == null ? null : (now - m.lastReportAtUs!) ~/ 1000;
      parts.add(ParticipantDiagnostics(
        deviceId: m.deviceId,
        errorUs: r?.errorUs,
        uncertaintyUs: r?.uncertaintyUs,
        offsetUs: r?.offsetUs,
        rttP95Us: r?.rttP95Us,
        mode: r?.mode ?? CorrectionMode.idle,
        lastReportAgeMs: age,
        rate: r?.rate ?? 1.0,
        playerState: r?.playerState ?? 'unknown',
        backend: m.caps.backend,
      ));
      if (r != null &&
          m.isConnected &&
          age != null &&
          age < 5000 &&
          r.generation == _state.timeline.generation &&
          (r.mode == CorrectionMode.inSync || r.mode == CorrectionMode.rateCorrecting)) {
        errs.add(r.errorUs);
      }
    }
    final maxPair = errs.length >= 2 ? errs.reduce(max) - errs.reduce(min) : null;
    _lastDiagnostics = DiagnosticsMsg(parts, maxPairwiseErrorUs: maxPair);
    if (!_diagCtl.isClosed) _diagCtl.add(_lastDiagnostics);
    for (final l in _links) {
      if (l.hs == _Hs.active) _send(l, _lastDiagnostics);
    }
  }

  // ------------------------------------------------------------ publish

  void _mutate(RoomState next, {bool timeline = false}) {
    _state = next.copyWith(version: _state.version + 1);
    if (timeline) _timelineVersion = _state.version;
    if (!_publishScheduled) {
      _publishScheduled = true;
      scheduleMicrotask(_flushPublish);
    }
  }

  void _flushPublish() {
    if (!_publishScheduled) return;
    _publishScheduled = false;
    final current = _state.timeline.trackId ?? _state.pending?.trackId;
    final summaries = [for (final m in _members.all) m.summary(current)];
    final playlist = [
      for (final t in _state.playlist)
        t.copyWith(
            availableCount: _members.connected
                .where((m) => m.availability[t.id] == TrackAvailability.available)
                .length)
    ];
    _state = _state.copyWith(participants: summaries, playlist: playlist);
    if (!_stateCtl.isClosed) _stateCtl.add(_state);
    final msg = StateMsg(_state);
    for (final l in _links) {
      if (l.hs == _Hs.active) _send(l, msg);
    }
  }

  void _send(_PeerLink link, Message m) {
    if (link.hs == _Hs.closed || !link.conn.isOpen) return;
    try {
      link.conn.send(link.codec.encode(m));
    } catch (e) {
      log.error('link.send', 'failed to send ${m.type} to ${link.member?.deviceId}: $e');
    }
  }

  static String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;
}
