import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../data/models.dart';
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
    try {
      final info = await _svc.join(
        identity: ref.read(identityProvider),
        host: host,
        port: port,
        joinKey: joinKey,
        roomId: roomId,
      );
      _attach(info);
    } catch (e) {
      state = RoomViewState(error: _describe(e));
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
    await _svc.leave();
    ref.invalidate(roomHistoryProvider);
    state = const RoomViewState();
  }

  void addTracks(List<LibraryTrack> tracks) => _svc.addTracks(tracks);

  /// Sends a control request; returns a user-facing error or null.
  Future<String?> control(ControlAction action,
      {int? positionUs, String? trackId, double? value, String? targetDevice, ParticipantRole? role}) async {
    final s = _svc.session;
    if (s == null) return 'Not in a room';
    final ack = await s.control(action,
        positionUs: positionUs, trackId: trackId, value: value, targetDevice: targetDevice, role: role);
    if (ack.accepted) return null;
    return switch (ack.error) {
      ControlError.unauthorized => 'You are a listener in this room. Ask the host for control.',
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
    _svc.session?.engine.outputCalibrationUs = outputCalibrationUs;
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
