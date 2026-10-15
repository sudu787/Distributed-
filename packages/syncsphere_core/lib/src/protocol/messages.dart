/// Typed protocol messages (schema version 1).
///
/// Every message has a stable short `type` string and a JSON body. Parsing
/// is strict (see [Reader]); unknown *fields* are ignored for forward
/// compatibility, unknown *types* are surfaced as [UnknownMessage] so the
/// receiver can log and drop them.
library;

import '../config/sync_config.dart';
import '../model/room_state.dart';
import 'reader.dart';

/// Wire protocol versions this build speaks.
const int kProtocolMin = 1;
const int kProtocolMax = 1;

sealed class Message {
  const Message();
  String get type;
  Map<String, Object?> toBody();

  static Message parse(String type, Map<String, Object?> body,
      {ProtocolLimits limits = const ProtocolLimits()}) {
    final r = Reader(body, type);
    switch (type) {
      case HelloMsg.kType:
        return HelloMsg.read(r);
      case ChallengeMsg.kType:
        return ChallengeMsg.read(r);
      case AuthMsg.kType:
        return AuthMsg.read(r);
      case WelcomeMsg.kType:
        return WelcomeMsg.read(r, limits);
      case RejectMsg.kType:
        return RejectMsg.read(r);
      case HeartbeatMsg.kType:
        return HeartbeatMsg.read(r);
      case ClockRequestMsg.kType:
        return ClockRequestMsg.read(r);
      case ClockResponseMsg.kType:
        return ClockResponseMsg.read(r);
      case StateMsg.kType:
        return StateMsg.read(r, limits);
      case ReadyMsg.kType:
        return ReadyMsg.read(r);
      case ControlMsg.kType:
        return ControlMsg.read(r);
      case ControlAckMsg.kType:
        return ControlAckMsg.read(r);
      case SyncReportMsg.kType:
        return SyncReportMsg.read(r);
      case PlaybackEventMsg.kType:
        return PlaybackEventMsg.read(r);
      case AvailabilityMsg.kType:
        return AvailabilityMsg.read(r, limits);
      case DiagnosticsMsg.kType:
        return DiagnosticsMsg.read(r);
      case ByeMsg.kType:
        return ByeMsg.read(r);
      case ErrorMsg.kType:
        return ErrorMsg.read(r);
      default:
        return UnknownMessage(type, body);
    }
  }
}

class UnknownMessage extends Message {
  @override
  final String type;
  final Map<String, Object?> body;
  const UnknownMessage(this.type, this.body);
  @override
  Map<String, Object?> toBody() => body;
}

// ------------------------------------------------------------- handshake --

/// Capabilities a participant advertises at join time.
class DeviceCapabilities {
  /// Backend can change playback rate (needed for gradual correction).
  final bool rateControl;

  /// Audio backend identifier, e.g. `media3-exoplayer`, `simulated`.
  final String backend;

  /// Device can download tracks from the host.
  final bool lanDownload;

  /// Device is able to take over as coordinator (failover candidate).
  final bool canHost;

  /// Port this device would serve the room on if promoted. The coordinator
  /// combines it with the address it sees the device connect from.
  final int? failoverPort;

  const DeviceCapabilities({
    required this.rateControl,
    required this.backend,
    this.lanDownload = true,
    this.canHost = false,
    this.failoverPort,
  });

  Map<String, Object?> toJson() => {
        'rate': rateControl,
        'backend': backend,
        'lan': lanDownload,
        'canHost': canHost,
        if (failoverPort != null) 'fport': failoverPort,
      };

  factory DeviceCapabilities.fromJson(Map<String, Object?> j) {
    final r = Reader(j, 'caps');
    return DeviceCapabilities(
      rateControl: r.boolean('rate'),
      backend: r.string('backend', maxLength: 64),
      lanDownload: r.optBoolean('lan') ?? false,
      canHost: r.optBoolean('canHost') ?? false,
      failoverPort: r.optInteger('fport', min: 1, max: 65535),
    );
  }
}

class HelloMsg extends Message {
  static const kType = 'hello';
  @override
  String get type => kType;

  final int protoMin;
  final int protoMax;
  final String deviceId;
  final String displayName;
  final String platform;
  final String clientNonce;
  final String? roomId;
  final DeviceCapabilities caps;

  const HelloMsg({
    this.protoMin = kProtocolMin,
    this.protoMax = kProtocolMax,
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.clientNonce,
    this.roomId,
    required this.caps,
  });

  @override
  Map<String, Object?> toBody() => {
        'pmin': protoMin,
        'pmax': protoMax,
        'dev': deviceId,
        'name': displayName,
        'plat': platform,
        'nonce': clientNonce,
        if (roomId != null) 'room': roomId,
        'caps': caps.toJson(),
      };

  static HelloMsg read(Reader r) => HelloMsg(
        protoMin: r.integer('pmin', min: 0, max: 1 << 16),
        protoMax: r.integer('pmax', min: 0, max: 1 << 16),
        deviceId: _deviceId(r, 'dev'),
        displayName: r.string('name', maxLength: 64, minLength: 1),
        platform: r.string('plat', maxLength: 32),
        clientNonce: r.string('nonce', minLength: 16, maxLength: 64),
        roomId: r.optString('room', maxLength: 64),
        caps: DeviceCapabilities.fromJson(r.map('caps')),
      );
}

class ChallengeMsg extends Message {
  static const kType = 'challenge';
  @override
  String get type => kType;

  final int protocol;
  final String roomId;
  final String roomName;
  final String coordinatorId;
  final int coordinatorEpoch;

  /// Random id of the coordinator *process*. A change means the
  /// coordinator's monotonic clock domain changed and every clock sample a
  /// participant holds is invalid.
  final String instance;
  final String serverNonce;

  /// PBKDF2 parameters so the client derives the same room key.
  final int kdfIterations;

  const ChallengeMsg({
    required this.protocol,
    required this.roomId,
    required this.roomName,
    required this.coordinatorId,
    required this.coordinatorEpoch,
    required this.instance,
    required this.serverNonce,
    required this.kdfIterations,
  });

  @override
  Map<String, Object?> toBody() => {
        'proto': protocol,
        'room': roomId,
        'name': roomName,
        'coord': coordinatorId,
        'epoch': coordinatorEpoch,
        'inst': instance,
        'nonce': serverNonce,
        'kdf': kdfIterations,
      };

  static ChallengeMsg read(Reader r) => ChallengeMsg(
        protocol: r.integer('proto', min: 0),
        roomId: r.string('room', maxLength: 64),
        roomName: r.string('name', maxLength: 64),
        coordinatorId: r.string('coord', maxLength: 64),
        coordinatorEpoch: r.integer('epoch', min: 0),
        instance: r.string('inst', maxLength: 64),
        serverNonce: r.string('nonce', minLength: 16, maxLength: 64),
        kdfIterations: r.integer('kdf', min: 1, max: 10000000),
      );
}

class AuthMsg extends Message {
  static const kType = 'auth';
  @override
  String get type => kType;

  /// HMAC proof that the client knows the room key.
  final String proof;

  /// Previous session id when reconnecting (keeps role/volume).
  final String? resumeSession;

  const AuthMsg({required this.proof, this.resumeSession});

  @override
  Map<String, Object?> toBody() => {
        'proof': proof,
        if (resumeSession != null) 'resume': resumeSession,
      };

  static AuthMsg read(Reader r) => AuthMsg(
        proof: r.string('proof', maxLength: 128),
        resumeSession: r.optString('resume', maxLength: 64),
      );
}

class WelcomeMsg extends Message {
  static const kType = 'welcome';
  @override
  String get type => kType;

  final String sessionId;
  final ParticipantRole role;

  /// HMAC proof that the server knows the room key (mutual auth).
  final String serverProof;
  final SyncConfig config;
  final RoomState state;

  const WelcomeMsg({
    required this.sessionId,
    required this.role,
    required this.serverProof,
    required this.config,
    required this.state,
  });

  @override
  Map<String, Object?> toBody() => {
        'session': sessionId,
        'role': role.name,
        'proof': serverProof,
        'config': config.toJson(),
        'state': state.toJson(),
      };

  static WelcomeMsg read(Reader r, ProtocolLimits limits) => WelcomeMsg(
        sessionId: r.string('session', maxLength: 64),
        role: r.enumValue('role', ParticipantRole.values),
        serverProof: r.string('proof', maxLength: 128),
        config: SyncConfig.fromJson(r.map('config')),
        state: RoomState.fromJson(r.map('state'),
            maxPlaylist: limits.maxPlaylistLength),
      );
}

/// Stable rejection codes.
abstract final class RejectCode {
  static const unsupportedVersion = 'unsupported_version';
  static const authFailed = 'auth_failed';
  static const roomFull = 'room_full';
  static const rateLimited = 'rate_limited';
  static const wrongRoom = 'wrong_room';
  static const timeout = 'handshake_timeout';
  static const protocolError = 'protocol_error';
  static const duplicateDevice = 'duplicate_device';
  static const roomClosed = 'room_closed';
}

class RejectMsg extends Message {
  static const kType = 'reject';
  @override
  String get type => kType;
  final String code;
  final String reason;
  const RejectMsg(this.code, this.reason);
  @override
  Map<String, Object?> toBody() => {'code': code, 'reason': reason};
  static RejectMsg read(Reader r) =>
      RejectMsg(r.string('code', maxLength: 64), r.string('reason', maxLength: 256));
}

// ------------------------------------------------------- steady state ----

class HeartbeatMsg extends Message {
  static const kType = 'hb';
  @override
  String get type => kType;
  final int senderTimeUs;
  const HeartbeatMsg(this.senderTimeUs);
  @override
  Map<String, Object?> toBody() => {'t': senderTimeUs};
  static HeartbeatMsg read(Reader r) => HeartbeatMsg(r.integer('t'));
}

class ClockRequestMsg extends Message {
  static const kType = 'clk.req';
  @override
  String get type => kType;
  final int id;
  final int t1;
  const ClockRequestMsg(this.id, this.t1);
  @override
  Map<String, Object?> toBody() => {'id': id, 't1': t1};
  static ClockRequestMsg read(Reader r) =>
      ClockRequestMsg(r.integer('id', min: 0), r.integer('t1'));
}

class ClockResponseMsg extends Message {
  static const kType = 'clk.res';
  @override
  String get type => kType;
  final int id;
  final int t1;
  final int t2;
  final int t3;
  const ClockResponseMsg(this.id, this.t1, this.t2, this.t3);
  @override
  Map<String, Object?> toBody() => {'id': id, 't1': t1, 't2': t2, 't3': t3};
  static ClockResponseMsg read(Reader r) => ClockResponseMsg(
      r.integer('id', min: 0), r.integer('t1'), r.integer('t2'), r.integer('t3'));
}

class StateMsg extends Message {
  static const kType = 'state';
  @override
  String get type => kType;
  final RoomState state;
  const StateMsg(this.state);
  @override
  Map<String, Object?> toBody() => {'state': state.toJson()};
  static StateMsg read(Reader r, ProtocolLimits limits) => StateMsg(
      RoomState.fromJson(r.map('state'), maxPlaylist: limits.maxPlaylistLength));
}

/// Participant → coordinator: result of preparing a pending segment.
class ReadyMsg extends Message {
  static const kType = 'ready';
  @override
  String get type => kType;
  final int generation;
  final String trackId;
  final bool ok;

  /// Failure code when `ok` is false: `missing_track`, `hash_mismatch`,
  /// `decode_error`, `download_failed`, `timeout`.
  final String? error;

  /// Participant's learned output start-latency compensation (µs).
  final int startLatencyUs;

  /// 95th-percentile clock-probe RTT (µs) and current uncertainty (µs), so
  /// the coordinator can size the scheduling lead.
  final int rttP95Us;
  final int uncertaintyUs;

  const ReadyMsg({
    required this.generation,
    required this.trackId,
    required this.ok,
    this.error,
    this.startLatencyUs = 0,
    this.rttP95Us = 0,
    this.uncertaintyUs = 0,
  });

  @override
  Map<String, Object?> toBody() => {
        'gen': generation,
        'track': trackId,
        'ok': ok,
        if (error != null) 'err': error,
        'lat': startLatencyUs,
        'rtt': rttP95Us,
        'unc': uncertaintyUs,
      };

  static ReadyMsg read(Reader r) => ReadyMsg(
        generation: r.integer('gen', min: 0),
        trackId: r.string('track', maxLength: 64),
        ok: r.boolean('ok'),
        error: r.optString('err', maxLength: 64),
        startLatencyUs: r.integer('lat', min: 0, max: 10000000),
        rttP95Us: r.integer('rtt', min: 0, max: 600000000),
        uncertaintyUs: r.integer('unc', min: 0, max: 600000000),
      );
}

enum ControlAction {
  play,
  pause,
  seek,
  setTrack,
  next,
  previous,
  masterVolume,
  deviceVolume,
  setRole,
}

/// Controller → coordinator playback/room command. [baseVersion] is the
/// state version the sender's UI was showing; the coordinator rejects
/// commands whose intent may have been invalidated by newer state.
class ControlMsg extends Message {
  static const kType = 'ctl';
  @override
  String get type => kType;
  final int requestId;
  final ControlAction action;
  final int baseVersion;
  final int? positionUs;
  final String? trackId;
  final double? value;
  final String? targetDevice;
  final ParticipantRole? role;

  const ControlMsg({
    required this.requestId,
    required this.action,
    required this.baseVersion,
    this.positionUs,
    this.trackId,
    this.value,
    this.targetDevice,
    this.role,
  });

  @override
  Map<String, Object?> toBody() => {
        'rid': requestId,
        'act': action.name,
        'base': baseVersion,
        if (positionUs != null) 'posUs': positionUs,
        if (trackId != null) 'track': trackId,
        if (value != null) 'val': value,
        if (targetDevice != null) 'dev': targetDevice,
        if (role != null) 'role': role!.name,
      };

  static ControlMsg read(Reader r) => ControlMsg(
        requestId: r.integer('rid', min: 0),
        action: r.enumValue('act', ControlAction.values),
        baseVersion: r.integer('base', min: 0),
        positionUs: r.optInteger('posUs', min: 0, max: 24 * 3600 * 1000000),
        trackId: r.optString('track', maxLength: 64),
        value: r.optNumber('val', min: 0, max: 1),
        targetDevice: r.optString('dev', maxLength: 64),
        role: r.optEnum('role', ParticipantRole.values),
      );
}

abstract final class ControlError {
  static const unauthorized = 'unauthorized';
  static const staleVersion = 'stale_version';
  static const invalid = 'invalid';
  static const unknownTrack = 'unknown_track';
  static const nothingToPlay = 'nothing_to_play';
  static const busy = 'busy';
  static const notConnected = 'not_connected';
}

class ControlAckMsg extends Message {
  static const kType = 'ctl.ack';
  @override
  String get type => kType;
  final int requestId;
  final bool accepted;
  final String? error;
  final int version;
  const ControlAckMsg({
    required this.requestId,
    required this.accepted,
    this.error,
    required this.version,
  });
  @override
  Map<String, Object?> toBody() => {
        'rid': requestId,
        'ok': accepted,
        if (error != null) 'err': error,
        'ver': version,
      };
  static ControlAckMsg read(Reader r) => ControlAckMsg(
        requestId: r.integer('rid', min: 0),
        accepted: r.boolean('ok'),
        error: r.optString('err', maxLength: 64),
        version: r.integer('ver', min: 0),
      );
}

/// Drift-correction mode a participant is in.
enum CorrectionMode { idle, inSync, rateCorrecting, resyncing, waiting }

/// Periodic participant → coordinator synchronization report. All errors are
/// *software estimates*: measured backend position vs. the timeline, through
/// the estimated clock offset. They are not acoustic measurements.
class SyncReportMsg extends Message {
  static const kType = 'rep';
  @override
  String get type => kType;
  final int generation;

  /// Coordinator-domain time of the measurement (estimated).
  final int coordTimeUs;
  final int positionUs;
  final int expectedUs;
  final int errorUs;
  final double rate;
  final int bufferedUs;
  final int offsetUs;
  final int uncertaintyUs;
  final int rttP95Us;
  final CorrectionMode mode;
  final String playerState;

  const SyncReportMsg({
    required this.generation,
    required this.coordTimeUs,
    required this.positionUs,
    required this.expectedUs,
    required this.errorUs,
    required this.rate,
    required this.bufferedUs,
    required this.offsetUs,
    required this.uncertaintyUs,
    required this.rttP95Us,
    required this.mode,
    required this.playerState,
  });

  @override
  Map<String, Object?> toBody() => {
        'gen': generation,
        'at': coordTimeUs,
        'pos': positionUs,
        'exp': expectedUs,
        'err': errorUs,
        'rate': rate,
        'buf': bufferedUs,
        'off': offsetUs,
        'unc': uncertaintyUs,
        'rtt': rttP95Us,
        'mode': mode.name,
        'ps': playerState,
      };

  static SyncReportMsg read(Reader r) => SyncReportMsg(
        generation: r.integer('gen', min: 0),
        coordTimeUs: r.integer('at'),
        positionUs: r.integer('pos'),
        expectedUs: r.integer('exp'),
        errorUs: r.integer('err'),
        rate: r.number('rate', min: 0.25, max: 4),
        bufferedUs: r.integer('buf', min: 0),
        offsetUs: r.integer('off'),
        uncertaintyUs: r.integer('unc', min: 0),
        rttP95Us: r.integer('rtt', min: 0),
        mode: r.enumValue('mode', CorrectionMode.values),
        playerState: r.string('ps', maxLength: 32),
      );
}

enum PlaybackEventKind {
  /// Backend started rendering a segment. `data.scheduledUs`/`actualUs`.
  started,

  /// Command arrived after its scheduled time; joined mid-stream.
  lateJoin,

  /// Corrective seek executed.
  resync,

  /// Buffer underrun / stall.
  stall,

  /// Rejoined synchronized playback after reconnecting.
  rejoined,
  error,
}

class PlaybackEventMsg extends Message {
  static const kType = 'evt';
  @override
  String get type => kType;
  final PlaybackEventKind kind;
  final int generation;
  final String? detail;
  final Map<String, num> data;
  const PlaybackEventMsg({
    required this.kind,
    required this.generation,
    this.detail,
    this.data = const {},
  });
  @override
  Map<String, Object?> toBody() => {
        'kind': kind.name,
        'gen': generation,
        if (detail != null) 'detail': detail,
        'data': data,
      };
  static PlaybackEventMsg read(Reader r) {
    final raw = r.optMap('data') ?? const {};
    if (raw.length > 32) throw r.error('data', 'too many entries');
    final data = <String, num>{};
    raw.forEach((k, v) {
      if (v is num && v.isFinite && k.length <= 32) data[k] = v;
    });
    return PlaybackEventMsg(
      kind: r.enumValue('kind', PlaybackEventKind.values),
      generation: r.integer('gen', min: 0),
      detail: r.optString('detail', maxLength: 256),
      data: data,
    );
  }
}

class TrackAvailabilityEntry {
  final String trackId;
  final TrackAvailability availability;
  const TrackAvailabilityEntry(this.trackId, this.availability);
}

class AvailabilityMsg extends Message {
  static const kType = 'avail';
  @override
  String get type => kType;
  final List<TrackAvailabilityEntry> tracks;
  const AvailabilityMsg(this.tracks);
  @override
  Map<String, Object?> toBody() => {
        'tracks': [
          for (final t in tracks) {'id': t.trackId, 'a': t.availability.name}
        ]
      };
  static AvailabilityMsg read(Reader r, ProtocolLimits limits) =>
      AvailabilityMsg([
        for (final m in r.mapList('tracks', maxLength: limits.maxPlaylistLength))
          () {
            final rr = Reader(m, 'avail.track');
            return TrackAvailabilityEntry(rr.string('id', maxLength: 64),
                rr.enumValue('a', TrackAvailability.values));
          }()
      ]);
}

/// Per-participant sync metrics the coordinator aggregates and rebroadcasts
/// for diagnostics screens. Not versioned state.
class ParticipantDiagnostics {
  final String deviceId;
  final int? errorUs;
  final int? uncertaintyUs;
  final int? offsetUs;
  final int? rttP95Us;
  final CorrectionMode mode;
  final int? lastReportAgeMs;
  final double rate;
  final String playerState;
  final String backend;

  const ParticipantDiagnostics({
    required this.deviceId,
    this.errorUs,
    this.uncertaintyUs,
    this.offsetUs,
    this.rttP95Us,
    this.mode = CorrectionMode.idle,
    this.lastReportAgeMs,
    this.rate = 1.0,
    this.playerState = 'unknown',
    this.backend = 'unknown',
  });

  Map<String, Object?> toJson() => {
        'id': deviceId,
        if (errorUs != null) 'err': errorUs,
        if (uncertaintyUs != null) 'unc': uncertaintyUs,
        if (offsetUs != null) 'off': offsetUs,
        if (rttP95Us != null) 'rtt': rttP95Us,
        'mode': mode.name,
        if (lastReportAgeMs != null) 'age': lastReportAgeMs,
        'rate': rate,
        'ps': playerState,
        'be': backend,
      };

  factory ParticipantDiagnostics.fromJson(Map<String, Object?> j) {
    final r = Reader(j, 'diag');
    return ParticipantDiagnostics(
      deviceId: r.string('id', maxLength: 64),
      errorUs: r.optInteger('err'),
      uncertaintyUs: r.optInteger('unc', min: 0),
      offsetUs: r.optInteger('off'),
      rttP95Us: r.optInteger('rtt', min: 0),
      mode: r.enumValue('mode', CorrectionMode.values),
      lastReportAgeMs: r.optInteger('age', min: 0),
      rate: r.number('rate', min: 0.25, max: 4),
      playerState: r.string('ps', maxLength: 32),
      backend: r.string('be', maxLength: 64),
    );
  }
}

class DiagnosticsMsg extends Message {
  static const kType = 'diag';
  @override
  String get type => kType;
  final List<ParticipantDiagnostics> participants;

  /// Estimated max pairwise playback-position error among in-sync
  /// participants (µs). Software estimate.
  final int? maxPairwiseErrorUs;
  const DiagnosticsMsg(this.participants, {this.maxPairwiseErrorUs});
  @override
  Map<String, Object?> toBody() => {
        'parts': [for (final p in participants) p.toJson()],
        if (maxPairwiseErrorUs != null) 'maxPair': maxPairwiseErrorUs,
      };
  static DiagnosticsMsg read(Reader r) => DiagnosticsMsg(
        [
          for (final m in r.mapList('parts', maxLength: 256))
            ParticipantDiagnostics.fromJson(m)
        ],
        maxPairwiseErrorUs: r.optInteger('maxPair', min: 0),
      );
}

class ByeMsg extends Message {
  static const kType = 'bye';
  @override
  String get type => kType;
  final String reason;
  const ByeMsg(this.reason);
  @override
  Map<String, Object?> toBody() => {'reason': reason};
  static ByeMsg read(Reader r) => ByeMsg(r.string('reason', maxLength: 256));
}

class ErrorMsg extends Message {
  static const kType = 'err';
  @override
  String get type => kType;
  final String code;
  final String reason;
  const ErrorMsg(this.code, this.reason);
  @override
  Map<String, Object?> toBody() => {'code': code, 'reason': reason};
  static ErrorMsg read(Reader r) =>
      ErrorMsg(r.string('code', maxLength: 64), r.string('reason', maxLength: 256));
}

final _deviceIdRe = RegExp(r'^[A-Za-z0-9_\-]{4,64}$');

String _deviceId(Reader r, String k) {
  final s = r.string(k, maxLength: 64);
  if (!_deviceIdRe.hasMatch(s)) throw r.error(k, 'invalid device id');
  return s;
}

bool isValidDeviceId(String s) => _deviceIdRe.hasMatch(s);
