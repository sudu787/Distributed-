import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_audio/syncsphere_audio.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../data/models.dart';
import '../services/network_info.dart';
import '../services/room_service.dart';
import 'providers.dart';

enum RoomStatus { none, starting, active, leaving }

/// Everything the room, player and diagnostics screens render.
class RoomViewState {
  final RoomStatus status;
  final RoomInfo? info;
  final RoomState? room;
  final SessionPhase? phase;
  final bool coordinatorSuspect;
  final DiagnosticsMsg? diagnostics;
  final EngineStatus? engine;
  final ClockEstimate? clock;
  final int rttP95Us;
  final ParticipantRole? role;
  final String? error;
  final List<SyncEvent> events;

  const RoomViewState({
    this.status = RoomStatus.none,
    this.info,
    this.room,
    this.phase,
    this.coordinatorSuspect = false,
    this.diagnostics,
    this.engine,
    this.clock,
    this.rttP95Us = 0,
    this.role,
    this.error,
    this.events = const [],
  });

  bool get isLive => phase == SessionPhase.joined || phase == SessionPhase.syncing;
  bool get canControl => isLive && (role?.canControl ?? false);
  bool get isHost => info?.isHost ?? false;

  RoomViewState copyWith({
    RoomStatus? status,
    RoomInfo? info,
    RoomState? room,
    SessionPhase? phase,
    bool? coordinatorSuspect,
    DiagnosticsMsg? diagnostics,
    EngineStatus? engine,
    ClockEstimate? clock,
    int? rttP95Us,
    ParticipantRole? role,
    String? error,
    bool clearError = false,
    List<SyncEvent>? events,
  }) =>
      RoomViewState(
        status: status ?? this.status,
        info: info ?? this.info,
        room: room ?? this.room,
        phase: phase ?? this.phase,
        coordinatorSuspect: coordinatorSuspect ?? this.coordinatorSuspect,
        diagnostics: diagnostics ?? this.diagnostics,
        engine: engine ?? this.engine,
        clock: clock ?? this.clock,
        rttP95Us: rttP95Us ?? this.rttP95Us,
        role: role ?? this.role,
        error: clearError ? null : (error ?? this.error),
        events: events ?? this.events,
      );
}

class RoomController extends Notifier<RoomViewState> {
  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _poll;

  RoomService get _svc => ref.read(roomServiceProvider);

  @override
  RoomViewState build() {
    ref.onDispose(_detach);
    return const RoomViewState();
  }

  Future<void> host({
    required String roomName,
    required DistributionMode distribution,
    required bool openControl,
  }) async {
    state = const RoomViewState(status: RoomStatus.starting);
    try {
      final tracks = await ref.read(libraryProvider.future);
      final info = await _svc.host(
        identity: ref.read(identityProvider),
        roomName: roomName,
        tracks: tracks,
        distribution: distribution,
        openControl: openControl,
      );
      _attach(info);
    } catch (e) {
      state = RoomViewState(error: _describe(e));
    }
  }

  Future<void> join({required String host, required int port, required String joinKey, String? roomId}) async {
    state = const RoomViewState(status: RoomStatus.starting);
    final err = await _tryJoin(host, port, joinKey, roomId);
    if (err != null) state = RoomViewState(error: _describe(err));
  }

  /// Rejoins the party this phone created (after the app was closed or
  /// crashed). It joins as a guest; the current host hands the host role
  /// back automatically once this phone has been stable for ~10 s.
  Future<void> rejoinHostedRoom(HostedRoom room, RoomBeacon beacon) =>
      join(host: beacon.host!, port: beacon.port, joinKey: room.joinKey, roomId: room.roomId);

  Future<void> forgetHostedRoom() async {
    await ref.read(appStoreProvider).saveHostedRoom(null);
    ref.invalidate(hostedRoomProvider);
  }

  /// Joins via a link, trying each advertised address until one answers.
  Future<void> joinWithLink(JoinLink link) async {
    state = const RoomViewState(status: RoomStatus.starting);
    Object? err;
    for (final h in link.hosts) {
      err = await _tryJoin(h, link.port, link.joinKey, link.roomId);
      if (err == null) return;
      if (!(err is SessionFailure && err.code == 'unreachable')) break;
    }
    state = RoomViewState(error: _describe(err!));
  }

  Future<Object?> _tryJoin(String host, int port, String joinKey, String? roomId) async {
    try {
      final info = await _svc.join(
        identity: ref.read(identityProvider),
        host: host,
        port: port,
        joinKey: joinKey,
        roomId: roomId,
      );
      _attach(info);
      return null;
    } catch (e) {
      return e;
    }
  }

  void _attach(RoomInfo info) {
    final s = _svc.session!;
    state = RoomViewState(status: RoomStatus.active, info: info, room: s.state, phase: s.phase, role: s.role);
    _subs
      ..add(s.stateStream.listen((r) => state = state.copyWith(room: r, role: s.role)))
      ..add(s.phaseStream.listen((p) => state = state.copyWith(
            phase: p,
            coordinatorSuspect: s.coordinatorSuspect,
            error: p == SessionPhase.failed ? s.lastFailure : null,
          )))
      ..add(s.diagnosticsStream.listen((d) => state = state.copyWith(diagnostics: d)))
      ..add(s.engine.statusStream.listen((e) => state = state.copyWith(engine: e)));
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final sess = _svc.session;
      if (sess == null) return;
      state = state.copyWith(
        info: _svc.info,
        clock: sess.estimate,
        rttP95Us: sess.rttP95Us,
        coordinatorSuspect: sess.coordinatorSuspect,
        events: _svc.log.recent(limit: 60, minLevel: EventLevel.info),
      );
    });
  }

  void _detach() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _poll?.cancel();
    _poll = null;
  }

  Future<void> leave() async {
    state = state.copyWith(status: RoomStatus.leaving);
    _detach();
    try {
      // Keep what acoustic calibration and latency learning found.
      final id = await _svc.persistCalibration();
      if (id != null) await ref.read(identityProvider.notifier).update(id);
    } catch (_) {
      // Best effort; leave() logs persistence failures too.
    }
    await _svc.leave();
    ref.invalidate(roomHistoryProvider);
    ref.invalidate(hostedRoomProvider);
    state = const RoomViewState();
  }

  void addTracks(List<LibraryTrack> tracks) => _svc.addTracks(tracks);

  /// Sends a control request; returns a user-facing error or null.
  Future<String?> control(ControlAction action,
      {int? positionUs,
      String? trackId,
      double? value,
      String? targetDevice,
      ParticipantRole? role,
      String? mode,
      int? offsetUs}) async {
    final s = _svc.session;
    if (s == null) return 'Not in a room';
    final ack = await s.control(action,
        positionUs: positionUs,
        trackId: trackId,
        value: value,
        targetDevice: targetDevice,
        role: role,
        mode: mode,
        offsetUs: offsetUs);
    if (ack.accepted) return null;
    return switch (ack.error) {
      ControlError.unauthorized => 'You are a listener in this room. Ask the host for control.',
      ControlError.busy => 'The room is calibrating. Try again in a few seconds.',
      ControlError.invalid when action == ControlAction.calibrate =>
        'Calibration needs microphone access and at least one connected device.',
      ControlError.staleVersion => 'The room changed meanwhile — try again.',
      ControlError.notConnected => 'Not connected to the room coordinator.',
      ControlError.nothingToPlay => 'Nothing to play.',
      ControlError.unknownTrack => 'That track is no longer in the room.',
      final other => 'Request failed: $other',
    };
  }

  Future<void> setCalibration(int outputCalibrationUs) async {
    final id = ref.read(identityProvider);
    await ref.read(identityProvider.notifier).update(id.copyWith(outputCalibrationUs: outputCalibrationUs));
    final s = _svc.session;
    if (s == null) return;
    // The room keeps each device's offset (acoustic calibration updates it
    // there too); offline, apply it locally.
    final err = await control(ControlAction.setCalibration, offsetUs: outputCalibrationUs);
    if (err != null) s.engine.outputCalibrationUs = outputCalibrationUs;
  }

  /// Manual timing fine-tune for any device (own device always; others
  /// need control rights). Positive = that device plays earlier.
  Future<String?> setDeviceOffset(String deviceId, int offsetUs) async {
    final v = offsetUs.clamp(-kMaxCalibrationUs, kMaxCalibrationUs);
    if (deviceId == ref.read(identityProvider).deviceId) {
      await setCalibration(v);
      return null;
    }
    return control(ControlAction.setCalibration, targetDevice: deviceId, offsetUs: v);
  }

  Future<String?> setRepeat(PlaylistRepeat mode) => control(ControlAction.setRepeat, mode: mode.name);

  Future<String?> setShuffle(bool on) => control(ControlAction.setShuffle, value: on ? 1 : 0);

  /// Channel role of [deviceId] (default: this device).
  Future<String?> setChannelRole(ChannelRole role, {String? deviceId}) =>
      control(ControlAction.setChannelRole, mode: role.name, targetDevice: deviceId);

  /// Starts an acoustic calibration measured by this device's microphone.
  Future<String?> calibrateHere() => control(ControlAction.calibrate);

  /// Whether this device can take part as the calibration listener.
  bool get hasMicrophone => _svc.session?.calibrationListener != null;

  /// Last calibration measured by this device's microphone.
  CalibrationOutcome? get lastCalibration => _svc.session?.calibrationListener?.lastOutcome;

  /// A JSON report of this device's sync state and recent events, for
  /// troubleshooting. Contains no join key and no audio.
  String diagnosticsReport({int maxEvents = 300}) {
    final s = _svc.session;
    final id = ref.read(identityProvider);
    final c = s?.estimate;
    final e = s?.engine.status;
    final backend = s?.backend;
    final cal = lastCalibration;
    final report = <String, Object?>{
      'kind': 'syncsphere-diagnostics-v1',
      'generatedAt': DateTime.now().toIso8601String(),
      'device': {
        'id': id.deviceId,
        'name': id.displayName,
        'savedOutputCalibrationUs': id.outputCalibrationUs,
        'savedStartLatencyUs': id.startLatencyUs,
        if (backend is Media3AudioBackend) 'audio': backend.deviceInfo,
        if (backend is Media3AudioBackend) 'bridgeUncertaintyUs': backend.bridge.estimate?.uncertaintyMicros.round(),
      },
      'session': {
        'phase': s?.phase.name,
        'role': s?.role?.name,
        'isHost': state.isHost,
        'rttP95Us': s?.rttP95Us,
      },
      if (c != null)
        'clock': {
          'offsetUs': c.offsetMicros.round(),
          'uncertaintyUs': c.uncertaintyMicros.round(),
          'skewPpm': double.parse(c.skewPpm.toStringAsFixed(2)),
          'samplesUsed': c.samplesUsed,
          'samplesInWindow': c.samplesInWindow,
          'minDelayUs': c.minDelayMicros,
          'method': c.method,
        },
      if (s != null && e != null)
        'engine': {
          'mode': e.mode.name,
          'lastErrorUs': e.lastErrorUs,
          'rate': e.rate,
          'startLatencyUs': e.startLatencyUs,
          'outputCalibrationUs': s.engine.outputCalibrationUs,
          'playerState': e.playerState,
          'resyncs': s.engine.drift.seekCount,
          'rateChanges': s.engine.drift.rateChangeCount,
          if (e.lastError != null) 'lastError': e.lastError,
        },
      if (cal != null)
        'lastCalibration': [
          for (final d in cal.devices)
            {
              'device': d.deviceId,
              'clicksHeard': d.arrivalsBySlot.length,
              'clicksExpected': d.expectedClicks,
              'arrivalsUs': {for (final a in d.arrivalsBySlot.entries) '${a.key}': a.value},
              'localCorrectionUs': d.correctionUs,
            }
        ],
      if (state.room != null) 'room': state.room!.toJson(),
      if (state.diagnostics != null) 'roomDiagnostics': state.diagnostics!.toBody(),
      'events': [for (final ev in _svc.log.recent(limit: maxEvents, minLevel: EventLevel.debug)) ev.toJson()],
    };
    return const JsonEncoder.withIndent(' ').convert(_jsonSafe(report));
  }

  static Object? _jsonSafe(Object? v) => switch (v) {
        null || bool() || String() => v,
        final num n => n.isFinite ? n : null,
        final Map<Object?, Object?> m => {for (final e in m.entries) '${e.key}': _jsonSafe(e.value)},
        final Iterable<Object?> l => [for (final x in l) _jsonSafe(x)],
        _ => v.toString(),
      };

  /// Join link for this room (host only; contains the join key).
  Future<JoinLink?> joinLink() async {
    final info = state.info;
    if (info == null || !info.isHost || info.joinKey == null) return null;
    final net = await readNetworkSummary();
    final hosts = rankLanAddresses(net.ipv4);
    if (hosts.isEmpty) return null;
    return JoinLink(hosts: hosts, port: info.port, joinKey: info.joinKey!, roomId: info.roomId);
  }


  /// Current expected track position (µs) of the room timeline, as seen
  /// through this device's clock estimate.
  int? expectedPositionUs() {
    final s = _svc.session;
    final r = state.room;
    final est = s?.estimate;
    if (r == null || est == null) return r?.timeline.anchorPositionUs;
    return r.timeline.expectedPositionAt(est.toRemote(_svc.clock.nowMicros()));
  }

  static String _describe(Object e) => switch (e) {
        SessionFailure(:final code, :final message) => switch (code) {
            'auth_failed' => 'Wrong join key.',
            'rate_limited' => 'Too many failed attempts. Wait a minute and retry.',
            'room_full' => 'The room is full.',
            'unreachable' => 'The room coordinator could not be reached.',
            _ => message,
          },
        _ => e.toString(),
      };
}

final roomControllerProvider = NotifierProvider<RoomController, RoomViewState>(RoomController.new);
