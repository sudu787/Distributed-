/// Participant session: connection lifecycle, authentication, clock probing,
/// coordinator failure detection and reconnection.
///
/// Phases:
///
///     idle → connecting → authenticating → syncing → joined
///                ↑                                     │ link lost / coordinator silent
///                └──────── reconnecting (backoff) ◄────┘
///     any → failed (fatal reject: wrong key, wrong room, version) | closed
///
/// While not `joined`/`syncing` the session refuses control requests: a
/// disconnected device can never steer the room with stale state. Playback
/// continues on the last known timeline using the extrapolated clock
/// estimate until the coordinator is back.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../audio/audio_backend.dart';
import '../config/sync_config.dart';
import '../coordinator/failure_detector.dart';
import '../distribution/swarm.dart';
import '../distribution/track_resolver.dart';
import '../model/room_state.dart';
import '../observability/event_log.dart';
import '../protocol/auth.dart';
import '../protocol/codec.dart';
import '../protocol/messages.dart';
import '../protocol/reader.dart';
import '../time/clock.dart';
import '../time/clock_sync.dart';
import '../transport/transport.dart';
import '../calibration/calibration_runtime.dart';
import 'failover.dart';
import 'playback_engine.dart';

enum SessionPhase { idle, connecting, authenticating, syncing, joined, reconnecting, failed, closed }

class SessionFailure implements Exception {
  final String code;
  final String message;
  const SessionFailure(this.code, this.message);
  @override
  String toString() => 'SessionFailure($code): $message';
}

/// Fatal reject codes: retrying cannot succeed.
const _fatalRejects = {
  RejectCode.authFailed,
  RejectCode.wrongRoom,
  RejectCode.unsupportedVersion,
  RejectCode.roomClosed,
  'server_auth_failed',
};

class ParticipantOptions {
  final String deviceId;
  final String displayName;
  final String platform;
  final String joinKey;

  /// Expected room id (from discovery). Null accepts whatever room answers.
  final String? roomId;
  final bool canHost;

  /// Base URI for LAN downloads (`http://host:port`), if known.
  final Uri? transferBase;
  final ReconnectConfig reconnect;
  final ProtocolLimits limits;

  /// Initial start-latency compensation (persisted from earlier sessions).
  final int initialStartLatencyUs;

  /// Acoustic output calibration (see [PlaybackEngine.outputCalibrationUs]).
  final int outputCalibrationUs;

  /// Derives the room key (PBKDF2). Defaults to synchronous derivation; apps
  /// pass an isolate-backed implementation so the UI does not stall.
  final Future<RoomKey> Function(String roomId, String joinKey, int iterations)? keyDeriver;

  /// Microphone access; makes this device able to lead a room calibration.
  final CalibrationRecorder? recorder;

  /// Where calibration click tracks are written (default: a temp folder).
  final CalibrationTrackFactory? calibrationTracks;

  /// Enables coordinator failover by succession (see `failover.dart`).
  /// Null keeps the conservative behaviour: report that the room is gone.
  final FailoverDelegate? failover;
  final FailoverPolicy failoverPolicy;

  /// Port of this device's peer file server (phone-to-phone sharing), if
  /// it runs one; advertised to the room.
  final int? peerPort;

  const ParticipantOptions({
    required this.deviceId,
    required this.displayName,
    this.platform = 'dart',
    required this.joinKey,
    this.roomId,
    this.canHost = false,
    this.transferBase,
    this.reconnect = const ReconnectConfig(),
    this.limits = const ProtocolLimits(),
    this.initialStartLatencyUs = 0,
    this.outputCalibrationUs = 0,
    this.keyDeriver,
    this.failover,
    this.failoverPolicy = const FailoverPolicy(),
    this.recorder,
    this.calibrationTracks,
    this.peerPort,
  });
}

class ParticipantSession implements ClockSource {
  final ParticipantOptions options;
  final Connector connector;
  final MonotonicClock clock;
  final AudioBackend backend;
  final TrackResolver resolver;
  final EventLog log;
  final Random _random;

  late final PlaybackEngine engine;
  CalibrationListener? calibrationListener;
  ClockSyncEstimator _estimator = ClockSyncEstimator();
  SyncConfig _config = const SyncConfig();

  SessionPhase _phase = SessionPhase.idle;
  RoomState? _state;
  DiagnosticsMsg? _diagnostics;
  ParticipantRole? _role;
  String? _sessionId;
  String? _coordinatorInstance;
  RoomKey? _roomKey;
  String? lastFailure;

  MessageConnection? _conn;
  FrameCodec? _codec;
  StreamSubscription<String>? _sub;
  _Hs _hs = _Hs.none;
  String? _clientNonce;
  ChallengeMsg? _challenge;
  Timer? _handshakeTimer;
  Timer? _heartbeatTimer;
  Timer? _livenessTimer;
  Timer? _probeTimer;
  int _lastHeardUs = 0;

  /// Judges the coordinator link (φ accrual by default); kept across
  /// reconnects so the learned heartbeat distribution survives.
  FailureDetector? _coordDetector;
  String? _coordDetectorConfig;

  /// The current link loss was declared by the failure detector (silence),
  /// not by the connection closing.
  bool _lostBySilence = false;

  /// Target and HTTP base of the last coordinator that welcomed us (where
  /// to go back to when holding off a self-promotion).
  Connector? _lastGoodTarget;
  Uri? _lastGoodBase;
  bool _holdLogged = false;
  bool _coordinatorSuspect = false;
  int _probeId = 0;
  int _burstRemaining = 0;
  final Map<int, int> _outstandingProbes = {};
  int _requestId = 0;
  final Map<int, Completer<ControlAckMsg>> _pendingControls = {};
  bool _closed = false;
  Completer<void>? _firstJoin;

  // Failover state.
  Connector? _target;

  /// HTTP base of the coordinator [_target] points at (downloads and
  /// uploads); null: [ParticipantOptions.transferBase].
  Uri? _targetBase;

  /// Transfer authorisation for the current session (null until welcomed).
  TransferContext? _transfer;
  int? _linkLostAtUs;
  int _candidateIndex = 0;
  int _candidateAttempts = 0;
  bool _promoted = false;

  /// True while [_target] points at a failover candidate we have not yet
  /// joined (as opposed to the coordinator we last joined).
  bool _tryingCandidate = false;

  /// Set when the coordinator redirected us elsewhere (handover/step-down).
  bool _redirected = false;
  int failoverCount = 0;

  /// Planned handovers this device accepted (it became coordinator).
  int handoverCount = 0;
  Completer<void>? _linkClosed;
  int reconnectCount = 0;

  final StreamController<SessionPhase> _phaseCtl = StreamController.broadcast();
  final StreamController<RoomState> _stateCtl = StreamController.broadcast();
  final StreamController<DiagnosticsMsg> _diagCtl = StreamController.broadcast();

  ParticipantSession({
    required this.options,
    required this.connector,
    required this.clock,
    required this.backend,
    required this.resolver,
    EventLog? log,
    Random? random,
  })  : log = log ?? EventLog(clock: clock, source: options.displayName),
        _random = random ?? Random() {
    engine = PlaybackEngine(
      backend: backend,
      resolver: resolver,
      clock: clock,
      clockSource: this,
      log: this.log,
      deviceId: options.deviceId,
      send: _sendIfActive,
      startLatencyUs: options.initialStartLatencyUs,
      outputCalibrationUs: options.outputCalibrationUs,
      calibrationTracks: options.calibrationTracks ??
          FileCalibrationTrackFactory(Directory('${Directory.systemTemp.path}/syncsphere-calibration')),
    );
    final rec = options.recorder;
    if (rec != null) {
      calibrationListener = CalibrationListener(
        deviceId: options.deviceId,
        recorder: rec,
        clock: clock,
        estimate: () => estimate,
        send: _sendIfActive,
        log: this.log,
      );
    }
  }

  // ---------------------------------------------------------- accessors

  SessionPhase get phase => _phase;
  Stream<SessionPhase> get phaseStream => _phaseCtl.stream;
  RoomState? get state => _state;
  Stream<RoomState> get stateStream => _stateCtl.stream;
  DiagnosticsMsg? get diagnostics => _diagnostics;
  Stream<DiagnosticsMsg> get diagnosticsStream => _diagCtl.stream;
  ParticipantRole? get role => _role;

  /// Room-wide key that authorises phone-to-phone chunk requests (null
  /// before the first handshake).
  List<int>? get peerKey => _roomKey?.peerKey();

  /// Other members' peer servers (not this device, not the coordinator,
  /// which serves the room anyway).
  List<PeerSource> _peerSources() {
    final s = _state;
    if (s == null) return const [];
    return [
      for (final p in s.participants)
        if (p.peer != null &&
            p.deviceId != options.deviceId &&
            p.deviceId != s.coordinatorId &&
            p.connection != ConnectionStatus.disconnected)
          if (Uri.tryParse('http://${p.peer}') case final u?) PeerSource(p.deviceId, u),
    ];
  }
  String? get sessionId => _sessionId;
  SyncConfig get config => _config;
  bool get isLive => _phase == SessionPhase.joined || _phase == SessionPhase.syncing;
  bool get coordinatorSuspect => _coordinatorSuspect;
  ClockSyncEstimator get estimator => _estimator;

  @override
  ClockEstimate? get estimate => _estimator.estimate;

  @override
  int get rttP95Us => _estimator.delayPercentile(0.95);

  // ---------------------------------------------------------- lifecycle

  /// Starts the connect/reconnect loop. Completes when first joined, or
  /// throws [SessionFailure] on a fatal rejection.
  Future<void> start() {
    if (_firstJoin != null) return _firstJoin!.future;
    _firstJoin = Completer<void>();
    unawaited(_runLoop());
    return _firstJoin!.future;
  }

  Future<void> _runLoop() async {
    var attempt = 0;
    while (!_closed) {
      _setPhase(attempt == 0 ? SessionPhase.connecting : SessionPhase.reconnecting);
      try {
        final conn = await (_target ?? connector)();
        if (_closed) {
          await conn.close('closed');
          break;
        }
        _linkClosed = Completer<void>();
        _attach(conn);
        await _linkClosed!.future;
        if (_hadJoinedThisLink) {
          attempt = 0;
          _linkLostAtUs = clock.nowMicros();
        }
      } on SessionFailure catch (f) {
        _fatal(f);
        return;
      } catch (e) {
        log.warn('session.connect', 'connection attempt failed: $e');
      }
      _detach();
      if (_closed || _phase == SessionPhase.failed) return;
      attempt++;
      try {
        if (await _maybeFailover()) {
          attempt = 0;
          continue;
        }
      } catch (e) {
        log.error('failover.error', 'failover step failed: $e');
      }
      final cfg = options.reconnect;
      if (cfg.maxAttempts > 0 && attempt > cfg.maxAttempts) {
        _fatal(const SessionFailure('unreachable', 'coordinator unreachable; the room may need to be recreated'));
        return;
      }
      final base = min(cfg.initialDelay.inMicroseconds * pow(cfg.multiplier, attempt - 1),
          cfg.maxDelay.inMicroseconds.toDouble());
      final jitter = base * cfg.jitter * (_random.nextDouble() * 2 - 1);
      var delayUs = (base + jitter).round();
      // Do not sleep past the failover deadline.
      final lost = _linkLostAtUs;
      if (options.failover != null && lost != null && !_promoted && !_tryingCandidate) {
        final untilFailover = _failoverDeadlineUs(lost) - clock.nowMicros();
        if (untilFailover > 0 && untilFailover < delayUs) delayUs = untilFailover + 1000;
      }
      final delay = Duration(microseconds: delayUs);
      _setPhase(SessionPhase.reconnecting);
      log.info('session.backoff', 'reconnecting in ${delay.inMilliseconds} ms (attempt $attempt)');
      await Future<void>.delayed(delay);
    }
  }

  bool _hadJoinedThisLink = false;

  /// Earliest time failover may start after losing the link at [lostUs].
  int _failoverDeadlineUs(int lostUs) {
    final p = options.failoverPolicy;
    final afterLoss = lostUs + p.failoverAfter.inMicroseconds;
    if (!_lostBySilence) return afterLoss;
    return max(afterLoss, _lastHeardUs + p.silenceBeforeFailover.inMicroseconds);
  }

  /// Decides whether to switch to (or become) a successor coordinator.
  /// Returns true when the connection target changed.
  Future<bool> _maybeFailover() async {
    final d = options.failover;
    final s = _state;
    final lost = _linkLostAtUs;
    if (d == null || s == null || lost == null || _promoted) return false;
    if (clock.nowMicros() < _failoverDeadlineUs(lost)) return false;
    final order = successionOrder(s);
    if (_tryingCandidate) {
      // Already trying a candidate: give it a few attempts, then move on.
      if (++_candidateAttempts < options.failoverPolicy.attemptsPerCandidate) return false;
      _candidateIndex++;
      _candidateAttempts = 0;
    }
    if (_candidateIndex >= order.length) {
      if (order.isNotEmpty && _tryingCandidate) {
        log.error('failover.exhausted', 'no failover candidate reachable');
      }
      return false;
    }
    final cand = order[_candidateIndex];
    failoverCount++;
    if (cand.deviceId == options.deviceId) {
      final p = options.failoverPolicy;
      final silent = clock.nowMicros() - _lastHeardUs;
      if (_candidateIndex > 0 &&
          _lostBySilence &&
          silent < (p.silenceBeforeFailover + p.isolationHoldOff).inMicroseconds) {
        // The coordinator went silent (no closed connection) and nobody
        // ahead of us in the succession order answered: most likely this
        // phone is the one cut off. Go round again, coordinator first. (A
        // closed connection means the coordinator process ended; then the
        // phones ahead are the ones that may be gone, so we go ahead.)
        if (!_holdLogged) {
          _holdLogged = true;
          log.warn('failover.hold', 'no successor ahead of this device answers; not taking over yet (this phone may be cut off)');
        }
        _target = _lastGoodTarget;
        _targetBase = _lastGoodBase;
        _tryingCandidate = false;
        _candidateIndex = 0;
        _candidateAttempts = 0;
        return false;
      }
      final est = estimate;
      final key = _roomKey;
      if (est == null || key == null) return false;
      final epoch = s.coordinatorEpoch + 1;
      log.warn('failover.promote', 'coordinator lost; this device takes over (epoch $epoch)');
      final translated = translateForSuccessor(s, estimate: est, newCoordinatorId: options.deviceId, newEpoch: epoch);
      _target = await d.promote(PromotionRequest(state: translated, epoch: epoch, roomKey: key, joinKey: options.joinKey));
      _targetBase = Uri.parse('http://127.0.0.1:${d.failoverPort}');
      _promoted = true;
      return true;
    }
    log.warn('failover.follow', 'coordinator lost; trying successor ${cand.displayName} (${cand.endpoint})');
    _target = d.connectorFor(cand.endpoint!);
    _targetBase = Uri.tryParse('http://${cand.endpoint}');
    _tryingCandidate = true;
    return true;
  }

  /// Planned leadership transfer to this device (the preferred host): start
  /// a coordinator at the given epoch with the current state translated into
  /// our clock, then confirm. The old coordinator redirects everyone here.
  Future<void> _onHandover(HandoverMsg h) async {
    final d = options.failover;
    final est = estimate;
    final key = _roomKey;
    final cur = _state;
    void nack(String why) {
      log.warn('handback.decline', 'declining host role: $why');
      _sendIfActive(HandoverAckMsg(epoch: h.epoch, ok: false, error: why));
    }

    if (d == null) return nack('this device cannot host');
    if (est == null || key == null) return nack('clock not synchronized yet');
    if (_promoted) return nack('already promoting');
    if (cur != null && h.epoch <= cur.coordinatorEpoch) return nack('stale epoch ${h.epoch}');
    try {
      final translated = translateForSuccessor(h.state, estimate: est, newCoordinatorId: options.deviceId, newEpoch: h.epoch);
      final connector = await d.promote(PromotionRequest(state: translated, epoch: h.epoch, roomKey: key, joinKey: options.joinKey));
      _target = connector;
      _targetBase = Uri.parse('http://127.0.0.1:${d.failoverPort}');
      _promoted = true;
      handoverCount++;
      log.info('handback.promoted', 'this device is the host again (epoch ${h.epoch})');
      _sendIfActive(HandoverAckMsg(epoch: h.epoch, ok: true));
    } catch (e) {
      nack('could not start: $e'.length > 200 ? 'could not start' : 'could not start: $e');
    }
  }

  /// The coordinator moved (handover or step-down): reconnect to [r] now
  /// instead of waiting for failure detection.
  void _onRedirect(RedirectMsg r) {
    final cur = _state;
    if (cur != null && r.epoch <= cur.coordinatorEpoch) {
      log.warn('session.redirect', 'ignoring redirect to older epoch ${r.epoch}');
      return;
    }
    if (_promoted) return; // we are the new coordinator
    final d = options.failover;
    if (d == null) {
      log.warn('session.redirect', 'coordinator moved to ${r.endpoint} but this device cannot follow automatically');
      return;
    }
    log.warn('session.redirect', 'coordinator moved to ${r.endpoint} (epoch ${r.epoch}, ${r.reason}); audio keeps playing');
    _target = d.connectorFor(r.endpoint);
    _targetBase = Uri.tryParse('http://${r.endpoint}');
    // Treated like a failover candidate: if it stays unreachable, fall back
    // to the succession order (starting with its first entry).
    _tryingCandidate = true;
    _candidateIndex = -1;
    _candidateAttempts = 0;
    _redirected = true;
    _linkDown('redirected to ${r.endpoint}');
  }

  void _fatal(SessionFailure f) {
    lastFailure = '${f.code}: ${f.message}';
    log.error('session.failed', lastFailure!);
    _detach();
    _setPhase(SessionPhase.failed);
    // The session is over (room ended, rejected, or unreachable for minutes):
    // stop the music instead of free-running on the last timeline, which is
    // only meant for temporary disconnects.
    unawaited(engine.dispose());
    if (_firstJoin != null && !_firstJoin!.isCompleted) _firstJoin!.completeError(f);
  }

  /// Leaves the room gracefully and stops playback.
  Future<void> leave() async {
    if (_closed) return;
    if (_hs == _Hs.active) _send(const ByeMsg('user left'));
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _detach();
    await engine.dispose();
    _setPhase(SessionPhase.closed);
    if (_firstJoin != null && !_firstJoin!.isCompleted) {
      _firstJoin!.completeError(const SessionFailure('closed', 'session closed'));
    }
    await _phaseCtl.close();
    await _stateCtl.close();
    await _diagCtl.close();
  }

  // ------------------------------------------------------------ link

  void _attach(MessageConnection conn) {
    _conn = conn;
    _codec = FrameCodec(limits: options.limits);
    _hs = _Hs.awaitChallenge;
    _hadJoinedThisLink = false;
    _clientNonce = newNonce();
    _setPhase(SessionPhase.authenticating);
    _sub = conn.incoming.listen(
      _onFrame,
      onDone: () => _linkDown('connection closed'),
      onError: (Object e) => _linkDown('link error: $e'),
    );
    _handshakeTimer = Timer(_config.membership.handshakeTimeout, () {
      if (_hs != _Hs.active) _linkDown('handshake timeout');
    });
    _send(HelloMsg(
      deviceId: options.deviceId,
      displayName: options.displayName,
      platform: options.platform,
      clientNonce: _clientNonce!,
      roomId: options.roomId,
      caps: DeviceCapabilities(
        rateControl: backend.capabilities.rateControl,
        backend: backend.capabilities.backend,
        canHost: options.canHost || options.failover != null,
        failoverPort: options.failover?.failoverPort,
        microphone: options.recorder != null,
        calibrationUs: engine.outputCalibrationUs,
        peerPort: options.peerPort,
        surround: true,
      ),
    ));
  }

  void _linkDown(String reason) {
    if (_linkClosed == null || _linkClosed!.isCompleted) return;
    log.warn('session.link', 'link down: $reason');
    final wasActive = _hs == _Hs.active;
    _hs = _Hs.none;
    if (wasActive) engine.onConnectionChanged(false);
    for (final c in _pendingControls.values) {
      if (!c.isCompleted) {
        c.complete(ControlAckMsg(requestId: -1, accepted: false, error: ControlError.notConnected, version: _state?.version ?? 0));
      }
    }
    _pendingControls.clear();
    _linkClosed!.complete();
  }

  void _completeLink() {
    final c = _linkClosed;
    if (c != null && !c.isCompleted) c.complete();
  }

  void _detach() {
    _handshakeTimer?.cancel();
    _heartbeatTimer?.cancel();
    _livenessTimer?.cancel();
    _probeTimer?.cancel();
    _outstandingProbes.clear();
    _sub?.cancel();
    _sub = null;
    _conn?.close();
    _conn = null;
    _hs = _Hs.none;
  }

  void _onFrame(String frame) {
    final t4 = clock.nowMicros(); // receive timestamp, before parsing
    final Message msg;
    try {
      msg = _codec!.decode(frame);
    } on ProtocolException catch (e) {
      log.error('session.protocol', 'bad frame from coordinator: $e');
      if (e.code == 'bad_mac' || e.code == 'replay' || _hs != _Hs.active) {
        _linkDown('integrity/handshake failure: ${e.code}');
      }
      return;
    }
    _lastHeardUs = t4;
    _coordDetector?.traffic(t4);
    if (_coordinatorSuspect) {
      _coordinatorSuspect = false;
      log.info('session.coordinator', 'coordinator responsive again');
    }
    switch (_hs) {
      case _Hs.awaitChallenge:
        if (msg is ChallengeMsg) {
          unawaited(_onChallenge(msg));
        } else if (msg is RejectMsg) {
          _onReject(msg);
        } else {
          _linkDown('expected challenge, got ${msg.type}');
        }
      case _Hs.awaitWelcome:
        if (msg is WelcomeMsg) {
          _onWelcome(msg);
        } else if (msg is RejectMsg) {
          _onReject(msg);
        } else {
          _linkDown('expected welcome, got ${msg.type}');
        }
      case _Hs.active:
        _onActive(msg, t4);
      case _Hs.none:
        break;
    }
  }

  void _onReject(RejectMsg r) {
    log.warn('session.rejected', 'rejected by coordinator: ${r.code} (${r.reason})');
    if (_fatalRejects.contains(r.code)) {
      _completeLink();
      _fatal(SessionFailure(r.code, r.reason));
    } else {
      _linkDown('rejected: ${r.code}');
    }
  }

  Future<void> _onChallenge(ChallengeMsg c) async {
    if (options.roomId != null && c.roomId != options.roomId) {
      _completeLink();
      _fatal(SessionFailure(RejectCode.wrongRoom, 'expected room ${options.roomId}, found ${c.roomId}'));
      return;
    }
    if (c.kdfIterations > 2000000) {
      _linkDown('coordinator requested unreasonable KDF cost');
      return;
    }
    if (_roomKey == null || _roomKey!.roomId != c.roomId || _roomKey!.iterations != c.kdfIterations) {
      final conn = _conn;
      final derive = options.keyDeriver;
      _roomKey = derive == null
          ? RoomKey.derive(roomId: c.roomId, joinKey: options.joinKey, iterations: c.kdfIterations)
          : await derive(c.roomId, options.joinKey, c.kdfIterations);
      if (!identical(conn, _conn) || _hs != _Hs.awaitChallenge) return; // link changed meanwhile
    }
    if (_coordinatorInstance != null && _coordinatorInstance != c.instance) {
      final cur = _state;
      final isFailover = cur != null && c.roomId == cur.roomId && c.coordinatorEpoch > cur.coordinatorEpoch;
      // Samples against the old coordinator's clock are meaningless now.
      _estimator = ClockSyncEstimator(config: _config.clock);
      if (isFailover) {
        log.warn('failover.joined', 'joined successor coordinator (epoch ${c.coordinatorEpoch}); audio keeps playing');
      } else {
        log.warn('session.clock', 'coordinator instance changed; discarding clock samples');
        engine.onClockDomainReset();
        _state = null;
      }
    }
    _coordinatorInstance = c.instance;
    _challenge = c;
    final proof = _roomKey!.clientProof(options.deviceId, _clientNonce!, c.serverNonce);
    _send(AuthMsg(proof: proof, resumeSession: _sessionId));
    final keys = _roomKey!.sessionKeys(options.deviceId, _clientNonce!, c.serverNonce);
    _codec!
      ..activate(sendKey: keys.clientToServer, recvKey: keys.serverToClient)
      ..allowPlainReject = true;
    _hs = _Hs.awaitWelcome;
  }

  void _onWelcome(WelcomeMsg w) {
    final c = _challenge!;
    final expected = _roomKey!.serverProof(options.deviceId, _clientNonce!, c.serverNonce);
    if (!constantTimeEquals(expected, w.serverProof)) {
      // The frame MAC already implies key knowledge; this is defence in depth.
      _completeLink();
      _fatal(const SessionFailure('server_auth_failed', 'coordinator failed to prove the room key'));
      return;
    }
    _handshakeTimer?.cancel();
    _codec!.allowPlainReject = false;
    _hs = _Hs.active;
    _hadJoinedThisLink = true;
    _linkLostAtUs = null;
    _lostBySilence = false;
    _holdLogged = false;
    _lastGoodTarget = _target;
    _lastGoodBase = _targetBase;
    _candidateIndex = 0;
    _candidateAttempts = 0;
    _promoted = false;
    _tryingCandidate = false;
    _redirected = false;
    if (_sessionId != null) reconnectCount++;
    _sessionId = w.sessionId;
    _role = w.role;
    _config = w.config;
    final rebuilt = ClockSyncEstimator(config: _config.clock);
    for (final s in _estimator.samples) {
      rebuilt.addSample(s, nowLocalMicros: clock.nowMicros());
    }
    _estimator = rebuilt;
    engine.updateConfig(_config);
    final keys = _roomKey!.sessionKeys(options.deviceId, _clientNonce!, c.serverNonce);
    final base = _targetBase ?? options.transferBase;
    _transfer = base == null
        ? null
        : TransferContext(
            baseUri: base,
            sessionId: w.sessionId,
            transferKey: keys.transfer,
            coordinatorNowMs: () {
              final e = estimate;
              final now = clock.nowMicros();
              return (e == null ? now : e.toRemote(now)) ~/ 1000;
            },
          );
    if (_transfer != null) resolver.setTransferContext(_transfer);
    resolver.setPeerContext(PeerContext(
      selfId: options.deviceId,
      peerKey: _roomKey!.peerKey(),
      coordinatorNowMs: () {
        final e = estimate;
        final now = clock.nowMicros();
        return (e == null ? now : e.toRemote(now)) ~/ 1000;
      },
      peers: _peerSources,
    ));
    log.info('session.joined', 'joined room ${c.roomId} as ${w.role.name}', {'session': w.sessionId});
    _setPhase(SessionPhase.syncing);
    _lastHeardUs = clock.nowMicros();
    final det = _coordDetector;
    if (det == null || _coordDetectorConfig != _config.membership.toJson().toString()) {
      _coordDetector = FailureDetector.forConfig(_config.membership, _lastHeardUs);
      _coordDetectorConfig = _config.membership.toJson().toString();
    } else {
      det.traffic(_lastHeardUs);
    }
    _startTimers();
    engine.onConnectionChanged(true);
    _applyState(w.state);
  }

  void _onActive(Message msg, int t4) {
    switch (msg) {
      case StateMsg(:final state):
        _applyState(state);
      case ClockResponseMsg(:final id, :final t1, :final t2, :final t3):
        final sent = _outstandingProbes.remove(id);
        if (sent == null || sent != t1) {
          log.debug('clock.unexpected', 'unexpected/duplicate clock response $id');
          return;
        }
        final res = _estimator.addSample(ClockSample(t1, t2, t3, t4), nowLocalMicros: t4);
        if (!res.accepted) {
          log.debug('clock.reject', 'sample rejected: ${res.rejection!.name}', {'delayUs': (t4 - t1) - (t3 - t2)});
        }
        if (_phase == SessionPhase.syncing && _estimator.acceptedCount >= 3) {
          _setPhase(SessionPhase.joined);
          if (_firstJoin != null && !_firstJoin!.isCompleted) _firstJoin!.complete();
        }
        engine.onClockUpdated();
      case HeartbeatMsg():
        _coordDetector?.heartbeat(t4);
      case ControlAckMsg():
        _pendingControls.remove(msg.requestId)?.complete(msg);
      case DiagnosticsMsg():
        _diagnostics = msg;
        if (!_diagCtl.isClosed) _diagCtl.add(msg);
      case HandoverMsg():
        unawaited(_onHandover(msg));
      case RedirectMsg():
        _onRedirect(msg);
      case ByeMsg(:final reason):
        if (_redirected) return; // moving to another coordinator
        log.warn('session.bye', 'coordinator said bye: $reason');
        _completeLink();
        _fatal(SessionFailure(RejectCode.roomClosed, reason));
      case ErrorMsg(:final code, :final reason):
        log.warn('session.error', 'coordinator reported error $code: $reason');
      case RejectMsg():
        _onReject(msg);
      case UnknownMessage(:final type):
        log.debug('protocol.unknown', 'ignoring unknown message "$type"');
      default:
        log.warn('protocol.unexpected', 'unexpected ${msg.type} from coordinator');
    }
  }

  void _applyState(RoomState s) {
    final cur = _state;
    if (cur != null && s.roomId == cur.roomId && s.coordinatorEpoch == cur.coordinatorEpoch && s.version <= cur.version) {
      log.debug('state.stale', 'ignoring stale state v${s.version} (have v${cur.version})');
      return;
    }
    if (cur != null && s.coordinatorEpoch < cur.coordinatorEpoch) {
      log.warn('state.epoch', 'ignoring state from older coordinator epoch ${s.coordinatorEpoch}');
      return;
    }
    _state = s;
    final me = s.participant(options.deviceId);
    if (me != null) _role = me.role;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
    engine.applyState(s);
    calibrationListener?.onState(s);
  }

  // ------------------------------------------------------------ timers

  void _startTimers() {
    final m = _config.membership;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(m.heartbeatInterval, (_) => _send(HeartbeatMsg(clock.nowMicros())));
    _livenessTimer?.cancel();
    _livenessTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final now = clock.nowMicros();
      final silent = now - _lastHeardUs;
      final det = _coordDetector ?? FailureDetector.forConfig(m, _lastHeardUs);
      if (det.isFailed(now)) {
        _lostBySilence = true;
        _linkDown('coordinator silent for ${silent ~/ 1000} ms (phi ${min(det.phi(now), 99).toStringAsFixed(1)})');
      } else if (det.isSuspect(now) && !_coordinatorSuspect) {
        _coordinatorSuspect = true;
        log.warn('session.coordinator', 'coordinator unresponsive for ${silent ~/ 1000} ms');
        _setPhase(_phase); // notify listeners
      }
      final timeout = _config.clock.probeTimeout.inMicroseconds;
      _outstandingProbes.removeWhere((_, t1) => clock.nowMicros() - t1 > timeout);
    });
    _burstRemaining = _config.clock.burstSamples;
    _scheduleProbe(Duration.zero);
  }

  void _scheduleProbe(Duration delay) {
    _probeTimer?.cancel();
    _probeTimer = Timer(delay, () {
      if (_hs != _Hs.active) return;
      final id = ++_probeId;
      final t1 = clock.nowMicros();
      _outstandingProbes[id] = t1;
      _send(ClockRequestMsg(id, t1));
      Duration next;
      if (_burstRemaining > 0) {
        _burstRemaining--;
        next = _config.clock.burstSpacing;
      } else {
        final e = _estimator.estimate;
        final stable = e != null &&
            e.uncertaintyMicros <= _config.clock.stableUncertainty.inMicroseconds &&
            e.samplesInWindow >= 8;
        next = stable ? _config.clock.slowInterval : _config.clock.fastInterval;
      }
      _scheduleProbe(next);
    });
  }

  // ------------------------------------------------------------ control

  /// Sends a control request based on the currently displayed state.
  Future<ControlAckMsg> control(
    ControlAction action, {
    int? positionUs,
    String? trackId,
    double? value,
    String? targetDevice,
    ParticipantRole? role,
    String? mode,
    int? offsetUs,
    TrackInfo? info,
    Duration timeout = const Duration(seconds: 5),
  }) {
    final version = _state?.version ?? 0;
    if (_hs != _Hs.active) {
      return Future.value(ControlAckMsg(
          requestId: -1, accepted: false, error: ControlError.notConnected, version: version));
    }
    final rid = ++_requestId;
    final c = Completer<ControlAckMsg>();
    _pendingControls[rid] = c;
    _send(ControlMsg(
      requestId: rid,
      action: action,
      baseVersion: version,
      positionUs: positionUs,
      trackId: trackId,
      value: value,
      targetDevice: targetDevice,
      role: role,
      mode: mode,
      offsetUs: offsetUs,
      info: info,
    ));
    return c.future.timeout(timeout, onTimeout: () {
      _pendingControls.remove(rid);
      return ControlAckMsg(requestId: rid, accepted: false, error: 'timeout', version: version);
    });
  }

  /// Adds a song from this device to the room: uploads [file] to the
  /// coordinator (`PUT /uploads/<id>`; the coordinator checks that its
  /// SHA-256 is [info].id and that this member may control the music), then
  /// appends it to the playlist. Every other device downloads it from the
  /// coordinator as usual. Songs already in the room are not re-sent.
  Future<ControlAckMsg> uploadTrack(
    File file,
    TrackInfo info, {
    void Function(int sent, int total)? onProgress,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final version = _state?.version ?? 0;
    ControlAckMsg fail(String error) => ControlAckMsg(requestId: -1, accepted: false, error: error, version: version);
    final ctx = _transfer;
    if (_hs != _Hs.active || ctx == null) return fail(ControlError.notConnected);
    if (!(_role?.canControl ?? false)) return fail(ControlError.unauthorized);
    if (_state?.trackById(info.id) != null) {
      return ControlAckMsg(requestId: -1, accepted: true, version: version);
    }
    final path = '/uploads/${info.id}';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final total = await file.length();
      final req = await client.openUrl('PUT', ctx.baseUri.replace(path: path));
      final expiry = ctx.coordinatorNowMs() + const TransferConfig().authValidity.inMilliseconds;
      req.headers.set('x-syncsphere-auth', signUpload(ctx.sessionId, ctx.transferKey, path, expiry));
      req.headers.contentType = ContentType('application', 'octet-stream');
      req.contentLength = total;
      var sent = 0;
      await req.addStream(file.openRead().map((chunk) {
        sent += chunk.length;
        onProgress?.call(sent, total);
        return chunk;
      }));
      final res = await req.close().timeout(timeout);
      final body = await res.transform(const SystemEncoding().decoder).join();
      if (res.statusCode != HttpStatus.created) {
        log.warn('upload.failed', 'upload of ${info.title} refused: HTTP ${res.statusCode} $body');
        return fail(res.statusCode == HttpStatus.forbidden
            ? ControlError.unauthorized
            : 'upload_failed: ${body.length > 80 ? body.substring(0, 80) : body}');
      }
      log.info('upload.done', 'uploaded ${info.title} ($total bytes)');
    } on Object catch (e) {
      log.warn('upload.failed', 'upload of ${info.title} failed: $e');
      return fail('upload_failed: $e');
    } finally {
      client.close(force: true);
    }
    return control(ControlAction.addTrack, info: info.copyWith(hostServes: true));
  }

  // ------------------------------------------------------------ sending

  void _sendIfActive(Message m) {
    if (_hs == _Hs.active) _send(m);
  }

  void _send(Message m) {
    final conn = _conn;
    final codec = _codec;
    if (conn == null || codec == null || !conn.isOpen) return;
    try {
      conn.send(codec.encode(m));
    } catch (e) {
      log.error('session.send', 'failed to send ${m.type}: $e');
    }
  }

  void _setPhase(SessionPhase p) {
    _phase = p;
    if (!_phaseCtl.isClosed) _phaseCtl.add(p);
  }
}

enum _Hs { none, awaitChallenge, awaitWelcome, active }
