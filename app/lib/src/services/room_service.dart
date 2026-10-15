import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:syncsphere_core/syncsphere_core.dart';

import '../data/app_store.dart';
import '../data/models.dart';

/// Default control/transfer port. Falls back to an ephemeral port if taken.
const int kDefaultRoomPort = 47800;

/// Platform side effects of being in a room (Wi-Fi locks, screen on).
abstract class PlatformHooks {
  Future<void> enterRoom();
  Future<void> leaveRoom();
}

class NoopPlatformHooks implements PlatformHooks {
  const NoopPlatformHooks();
  @override
  Future<void> enterRoom() async {}
  @override
  Future<void> leaveRoom() async {}
}

typedef BackendFactory = Future<AudioBackend> Function(EventLog log);

/// Derives the room key off the UI isolate (PBKDF2 is intentionally slow).
Future<RoomKey> deriveRoomKeyInIsolate(String roomId, String joinKey, int iterations) =>
    Isolate.run(() => RoomKey.derive(roomId: roomId, joinKey: joinKey, iterations: iterations));

class RoomInfo {
  final bool isHost;
  final String roomId;
  final String roomName;

  /// Only known on the host (it is never sent over the network).
  final String? joinKey;
  final String host;
  final int port;
  const RoomInfo({
    required this.isHost,
    required this.roomId,
    required this.roomName,
    this.joinKey,
    required this.host,
    required this.port,
  });
}

/// Owns everything a device runs while in a room. Exactly one room at a
/// time. Not a widget concern: Riverpod's RoomController wraps it.
class RoomService {
  final AppStore store;
  final BackendFactory backendFactory;
  final PlatformHooks hooks;
  final Directory cacheDir;
  final MonotonicClock clock;
  final Future<RoomKey> Function(String, String, int) keyDeriver;
  final int kdfIterations;

  final EventLog log;
  RoomCoordinator? coordinator;
  ParticipantSession? session;
  RoomInfo? info;
  WebSocketServer? _server;
  BeaconBroadcaster? _beacon;
  TrackFileServer? _files;
  TrackDownloader? _downloader;
  final Map<String, File> _served = {};
  DeviceIdentity? _identity;

  RoomService({
    required this.store,
    required this.backendFactory,
    required this.cacheDir,
    this.hooks = const NoopPlatformHooks(),
    MonotonicClock? clock,
    this.keyDeriver = deriveRoomKeyInIsolate,
    this.kdfIterations = kDefaultKdfIterations,
    EventLog? log,
  })  : clock = clock ?? SystemMonotonicClock.instance,
        log = log ?? EventLog(clock: clock ?? SystemMonotonicClock.instance, source: 'room', capacity: 3000);

  bool get inRoom => session != null;

  /// Creates a room hosted on this device and joins it with this device's
  /// own player. Throws on failure (and cleans up).
  Future<RoomInfo> host({
    required DeviceIdentity identity,
    required String roomName,
    required List<LibraryTrack> tracks,
    DistributionMode distribution = DistributionMode.auto,
    bool openControl = false,
    int port = kDefaultRoomPort,
  }) async {
    if (inRoom) throw StateError('already in a room');
    final joinKey = generateJoinKey();
    final roomId = generateJoinKey(length: 6);
    try {
      final key = await keyDeriver(roomId, joinKey, kdfIterations);
      final coord = RoomCoordinator(
        options: CoordinatorOptions(
          roomId: roomId,
          roomName: roomName,
          coordinatorId: identity.deviceId,
          joinKey: joinKey,
          kdfIterations: kdfIterations,
          defaultRole: openControl ? ParticipantRole.controller : ParticipantRole.listener,
          distribution: distribution,
          roomKey: key,
        ),
        clock: clock,
        log: log,
      );
      coordinator = coord;
      _served
        ..clear()
        ..addEntries(tracks.map((t) => MapEntry(t.id, File(t.path))));
      coord.setPlaylist([for (final t in tracks) t.toTrackInfo()]);
      _files = TrackFileServer(
        fileForTrack: (id) => _served[id],
        keysForSession: coord.transferKeysForSession,
        nowMs: () => clock.nowMicros() ~/ 1000,
        log: log,
      );
      _server = await _bind(port);
      coord.serve(_server!);
      coord.start();
      _beacon = BeaconBroadcaster(
        beacon: () => RoomBeacon(
          roomId: roomId,
          roomName: coord.state.roomName,
          coordinatorId: identity.deviceId,
          coordinatorEpoch: coord.state.coordinatorEpoch,
          port: _server!.port,
          participants: coord.state.participants.length,
        ),
      );
      try {
        await _beacon!.start();
      } on SocketException catch (e) {
        log.warn('discovery.beacon', 'cannot broadcast discovery beacons: ${e.message}');
      }
      info = RoomInfo(isHost: true, roomId: roomId, roomName: roomName, joinKey: joinKey, host: '127.0.0.1', port: _server!.port);
      await _startSession(identity, joinKey: joinKey, host: '127.0.0.1', port: _server!.port, roomId: roomId, key: key);
      await store.addRoomHistory(RoomHistoryEntry(
          roomId: roomId, roomName: roomName, host: 'this device', port: _server!.port, hosted: true, at: DateTime.now()));
      return info!;
    } catch (e) {
      log.error('room.host', 'failed to host room: $e');
      await leave();
      rethrow;
    }
  }

  Future<WebSocketServer> _bind(int port) async {
    try {
      return await WebSocketServer.bind(port: port, httpHandler: _files!.handle, onError: _serverError);
    } on SocketException {
      log.warn('room.port', 'port $port busy; using an ephemeral port');
      return WebSocketServer.bind(port: 0, httpHandler: _files!.handle, onError: _serverError);
    }
  }

  void _serverError(Object e, StackTrace st) => log.error('server', '$e');

  /// Joins a room hosted elsewhere. Throws [SessionFailure] on rejection.
  Future<RoomInfo> join({
    required DeviceIdentity identity,
    required String host,
    required int port,
    required String joinKey,
    String? roomId,
  }) async {
    if (inRoom) throw StateError('already in a room');
    try {
      await _startSession(identity, joinKey: joinKey, host: host, port: port, roomId: roomId);
      final s = session!.state!;
      info = RoomInfo(isHost: false, roomId: s.roomId, roomName: s.roomName, host: host, port: port);
      await store.addRoomHistory(RoomHistoryEntry(
          roomId: s.roomId, roomName: s.roomName, host: host, port: port, hosted: false, at: DateTime.now()));
      return info!;
    } catch (e) {
      log.error('room.join', 'failed to join $host:$port: $e');
      await leave();
      rethrow;
    }
  }

  Future<void> _startSession(
    DeviceIdentity identity, {
    required String joinKey,
    required String host,
    required int port,
    String? roomId,
    RoomKey? key,
  }) async {
    _identity = identity;
    final library = await store.libraryTracks();
    _downloader = TrackDownloader(log: log);
    final backend = await backendFactory(log);
    final s = ParticipantSession(
      options: ParticipantOptions(
        deviceId: identity.deviceId,
        displayName: identity.displayName,
        platform: Platform.operatingSystem,
        joinKey: joinKey,
        roomId: roomId,
        transferBase: Uri.parse('http://$host:$port'),
        initialStartLatencyUs: identity.startLatencyUs,
        outputCalibrationUs: identity.outputCalibrationUs,
        keyDeriver: (r, k, i) => key != null && key.roomId == r && key.iterations == i
            ? Future.value(key)
            : keyDeriver(r, k, i),
      ),
      connector: webSocketConnector(host, port),
      clock: clock,
      backend: backend,
      resolver: LibraryTrackResolver(
        library: {for (final t in library) t.id: File(t.path)},
        cache: TrackCache(Directory('${cacheDir.path}/tracks')),
        downloader: _downloader!,
        log: log,
      ),
      log: log,
    );
    session = s;
    await s.start();
    await hooks.enterRoom();
  }

  /// Host only: offers more library tracks to the room.
  void addTracks(List<LibraryTrack> tracks) {
    final c = coordinator;
    if (c == null) throw StateError('only the host can add tracks');
    for (final t in tracks) {
      _served[t.id] = File(t.path);
      c.addTrack(t.toTrackInfo());
    }
  }

  /// Saves what this device learned (start latency) for next time.
  Future<void> persistCalibration() async {
    final s = session;
    final id = _identity;
    if (s == null || id == null) return;
    final learned = s.engine.startLatencyUs;
    if (learned != id.startLatencyUs) {
      _identity = id.copyWith(startLatencyUs: learned);
      await store.saveIdentity(_identity!);
    }
  }

  Future<void> leave() async {
    try {
      await persistCalibration();
    } catch (e) {
      log.warn('room.persist', 'could not save calibration: $e');
    }
    final s = session;
    session = null;
    if (s != null) await s.leave();
    _beacon?.stop();
    _beacon = null;
    final c = coordinator;
    coordinator = null;
    if (c != null) await c.close(reason: 'host left; room closed');
    await _server?.close();
    _server = null;
    _downloader?.close();
    _downloader = null;
    info = null;
    await hooks.leaveRoom();
  }
}
