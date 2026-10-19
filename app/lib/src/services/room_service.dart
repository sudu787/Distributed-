import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:syncsphere_core/syncsphere_core.dart';

import '../data/app_store.dart';
import '../data/models.dart';

/// Default control/transfer port. Falls back to an ephemeral port if taken.
const int kDefaultRoomPort = 47800;

/// Platform side effects of being in a room (Wi-Fi locks, screen on,
/// background playback notification).
abstract class PlatformHooks {
  const PlatformHooks();
  Future<void> enterRoom(String roomName) async {}
  Future<void> leaveRoom() async {}

  /// Puts the app in the background without closing it (the party keeps
  /// running). Returns false where unsupported.
  Future<bool> moveToBackground() async => false;

  /// Keeps a "now playing" notification current.
  Future<void> nowPlaying({required String roomName, required String text, required bool playing}) async {}

  /// Room commands from outside the app UI (notification buttons):
  /// "play", "pause", "next", "previous".
  Stream<String> get commands => const Stream.empty();
}

class NoopPlatformHooks extends PlatformHooks {
  const NoopPlatformHooks();
}

typedef BackendFactory = Future<AudioBackend> Function(EventLog log);

/// Microphone access for acoustic calibration, if the backend has one.
typedef RecorderFactory = CalibrationRecorder? Function(AudioBackend backend);

/// Exact-seek conversion (see `ConvertingTrackResolver`), if the backend has one.
typedef ConverterFactory = SourceConverter? Function(AudioBackend backend);

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
  final RecorderFactory? recorderFor;
  final ConverterFactory? converterFor;

  /// Port this device serves on if it becomes coordinator through failover or
  /// handback (advertised to the room when joining).
  final int failoverPort;

  /// While coordinating, listen for discovery beacons of the same room with
  /// a higher epoch and step down (split-brain resolution). Off in tests.
  final bool watchForNewerCoordinator;

  /// When a temporary host hands the role back to the original host.
  final HandbackPolicy handbackPolicy;

  final EventLog log;
  RoomCoordinator? coordinator;
  ParticipantSession? session;
  RoomInfo? info;
  WebSocketServer? _server;
  BeaconBroadcaster? _beacon;
  TrackFileServer? _files;
  TrackDownloader? _downloader;
  SwarmDownloader? _swarm;
  final Map<String, File> _served = {};

  /// Chunk hashes of songs this phone serves (phone-to-phone sharing).
  final ChunkIndex _chunks = ChunkIndex();
  final Set<String> _rootsRequested = {};
  StreamSubscription<RoomState>? _rootSub;

  /// This phone's peer file server: other guests fetch song chunks from it.
  HttpServer? _peerServer;
  TrackFileServer? _peerFiles;
  DeviceIdentity? _identity;
  final List<StreamSubscription<Object?>> _subs = [];
  RoomDiscovery? _watch;
  StreamSubscription<List<RoomBeacon>>? _watchSub;

  /// True once this device took over as coordinator after the original
  /// host disappeared.
  bool promotedByFailover = false;

  RoomService({
    required this.store,
    required this.backendFactory,
    required this.cacheDir,
    this.hooks = const NoopPlatformHooks(),
    MonotonicClock? clock,
    this.keyDeriver = deriveRoomKeyInIsolate,
    this.kdfIterations = kDefaultKdfIterations,
    this.recorderFor,
    this.converterFor,
    this.failoverPort = kDefaultRoomPort,
    this.watchForNewerCoordinator = true,
    this.handbackPolicy = const HandbackPolicy(),
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
          handback: handbackPolicy,
        ),
        clock: clock,
        log: log,
      );
      coordinator = coord;
      _served
        ..clear()
        ..addEntries(tracks.map((t) => MapEntry(t.id, File(t.path))));
      coord.setPlaylist([for (final t in tracks) t.toTrackInfo()]);
      _files = _fileServerFor(coord);
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
      _attachCoordinator(coord);
      // Remembered so this phone can rejoin and get the host role back if the
      // app is closed or crashes (cleared when the party is ended on purpose).
      await store.saveHostedRoom(HostedRoom(roomId: roomId, roomName: roomName, joinKey: joinKey, startedAt: DateTime.now()));
      await _startSession(identity, joinKey: joinKey, host: '127.0.0.1', port: _server!.port, roomId: roomId, key: key);
      await store.addRoomHistory(RoomHistoryEntry(
          roomId: roomId,
          roomName: roomName,
          host: 'this device',
          port: _server!.port,
          hosted: true,
          at: DateTime.now(),
          joinKey: joinKey));
      return info!;
    } catch (e) {
      log.error('room.host', 'failed to host room: $e');
      await leave();
      rethrow;
    }
  }

  /// Failover (this device was elected successor) or handback (this device
  /// is the preferred host and the current coordinator handed the role
  /// back). Starts serving the room with the translated last state and
  /// returns a connector for our own session.
  Future<Connector> _promote(PromotionRequest req, DeviceIdentity identity) async {
    final library = await store.libraryTracks();
    _served
      ..clear()
      ..addEntries(library.map((t) => MapEntry(t.id, File(t.path))));
    // Songs this phone downloaded (including ones guests uploaded to the
    // previous host) can be served too, so they survive the host change.
    for (final t in req.state.playlist) {
      if (_served.containsKey(t.id)) continue;
      final cached = _cache.fileFor(t.id);
      if (await cached.exists()) _served[t.id] = cached;
    }
    final state = req.state.copyWith(playlist: [
      for (final t in req.state.playlist) t.copyWith(hostServes: _served.containsKey(t.id)),
    ]);
    final coord = RoomCoordinator(
      options: CoordinatorOptions(
        roomId: state.roomId,
        roomName: state.roomName,
        coordinatorId: identity.deviceId,
        joinKey: req.joinKey,
        kdfIterations: req.roomKey.iterations,
        roomKey: req.roomKey,
        coordinatorEpoch: req.epoch,
        distribution: state.distribution,
        defaultRole: ParticipantRole.listener,
        handback: handbackPolicy,
      ),
      clock: clock,
      log: log,
      restoredState: state,
    );
    coordinator = coord;
    _files = _fileServerFor(coord);
    _server = await _bind(failoverPort);
    if (_server!.port != failoverPort) {
      log.warn('failover.port', 'port $failoverPort busy; other members may not find this coordinator');
    }
    coord.serve(_server!);
    coord.start();
    _beacon = BeaconBroadcaster(
      beacon: () => RoomBeacon(
        roomId: state.roomId,
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
    final preferred = state.preferredCoordinator == identity.deviceId;
    promotedByFailover = !preferred;
    info = RoomInfo(
        isHost: true, roomId: state.roomId, roomName: state.roomName, joinKey: req.joinKey, host: '127.0.0.1', port: _server!.port);
    _attachCoordinator(coord);
    log.warn(
        preferred ? 'handback.host' : 'failover.host',
        preferred
            ? 'this device is the host again (epoch ${req.epoch})'
            : 'this device is now the room coordinator (epoch ${req.epoch})');
    return webSocketConnector('127.0.0.1', _server!.port);
  }

  /// Wiring shared by a hosted, a failed-over and a handed-back coordinator.
  /// Publishes chunk roots only for the songs about to play (pending,
  /// current and next), computed on a background isolate, instead of hashing
  /// the whole library when the party starts.
  void _watchChunkRoots(RoomCoordinator coord) {
    unawaited(_rootSub?.cancel());
    _rootsRequested.clear();
    void check(RoomState st) {
      final ids = <String>{
        if (st.pending != null) st.pending!.trackId,
        if (st.timeline.trackId != null) st.timeline.trackId!,
      };
      final cur = st.pending?.trackId ?? st.timeline.trackId;
      final i = cur == null ? -1 : st.playlist.indexWhere((t) => t.id == cur);
      if (i >= 0 && i + 1 < st.playlist.length) ids.add(st.playlist[i + 1].id);
      if (cur == null && st.playlist.isNotEmpty) ids.add(st.playlist.first.id);
      final todo = <String, File>{
        for (final id in ids)
          if (!_rootsRequested.contains(id) && st.trackById(id)?.chunkRoot == null && _served[id] != null) id: _served[id]!,
      };
      if (todo.isEmpty) return;
      _rootsRequested.addAll(todo.keys);
      unawaited(_publishChunkRoots(coord, todo));
    }

    check(coord.state);
    _rootSub = coord.stateStream.listen(check);
  }

  void _stopChunkRoots() {
    unawaited(_rootSub?.cancel());
    _rootSub = null;
    _rootsRequested.clear();
  }

  void _attachCoordinator(RoomCoordinator coord) {
    _watchChunkRoots(coord);
    coord.onSteppedDown = (endpoint, epoch, reason) => _onSteppedDown(coord, endpoint, epoch, reason);
    _stopWatch();
    if (!watchForNewerCoordinator) return;
    final d = RoomDiscovery();
    _watch = d;
    unawaited(() async {
      try {
        await d.start();
        if (!identical(_watch, d)) return;
        _watchSub = d.rooms.listen((rooms) => rooms.forEach(handleBeacon));
      } catch (e) {
        log.warn('discovery.watch', 'cannot watch for other coordinators: $e');
      }
    }());
  }

  void _stopWatch() {
    unawaited(_watchSub?.cancel());
    _watchSub = null;
    final w = _watch;
    _watch = null;
    if (w != null) unawaited(w.stop());
  }

  /// Split-brain resolution: a beacon for our room from a coordinator with a
  /// higher epoch (e.g. after our Wi-Fi came back) means we must step down
  /// and follow it.
  void handleBeacon(RoomBeacon b) {
    final c = coordinator;
    final host = b.host;
    if (c == null || host == null) return;
    if (b.roomId != c.state.roomId || b.coordinatorEpoch <= c.state.coordinatorEpoch) return;
    c.stepDown(endpoint: '$host:${b.port}', epoch: b.coordinatorEpoch);
  }

  /// The coordinator on this device redirected everyone elsewhere (handover
  /// or step-down): stop serving, keep playing as a guest.
  void _onSteppedDown(RoomCoordinator coord, String endpoint, int epoch, String reason) {
    if (!identical(coordinator, coord)) return;
    log.warn('room.stepdown',
        reason == 'handover' ? 'host role handed to $endpoint (epoch $epoch)' : 'a newer coordinator runs at $endpoint; following it');
    _stopWatch();
    _stopChunkRoots();
    coordinator = null;
    promotedByFailover = false;
    _beacon?.stop();
    _beacon = null;
    final server = _server;
    _server = null;
    // Give the redirects time to flush before the listening socket goes away.
    Timer(const Duration(seconds: 2), () => unawaited(server?.close()));
    final i = info;
    final sep = endpoint.lastIndexOf(':');
    if (i != null) {
      info = RoomInfo(
        isHost: false,
        roomId: i.roomId,
        roomName: i.roomName,
        host: endpoint.substring(0, sep),
        port: int.tryParse(endpoint.substring(sep + 1)) ?? failoverPort,
      );
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

  TrackCache get _cache => TrackCache(Directory('${cacheDir.path}/tracks'));

  /// Computes and publishes chunk roots so guests can share songs with each
  /// other. Runs in the background; a song without a root is simply
  /// downloaded whole from the host.
  Future<void> _publishChunkRoots(RoomCoordinator coord, Map<String, File> files) async {
    for (final e in files.entries) {
      try {
        final root = await _chunks.rootFor(e.key, e.value);
        if (identical(coordinator, coord)) coord.setChunkRoot(e.key, root);
      } catch (err) {
        log.warn('swarm.index', 'could not index ${e.key.substring(0, 8)} for sharing: $err');
      }
    }
  }

  /// Serves the room's songs and accepts songs uploaded by guests who may
  /// control the music. Uploads go into the track cache, where this phone's
  /// own player finds them too.
  TrackFileServer _fileServerFor(RoomCoordinator coord) {
    coord.trackAvailable = _served.containsKey;
    final cache = _cache;
    return TrackFileServer(
      fileForTrack: (id) => _served[id],
      keysForSession: coord.transferKeysForSession,
      nowMs: () => clock.nowMicros() ~/ 1000,
      log: log,
      canUpload: coord.canControlSession,
      uploadDir: Directory('${cacheDir.path}/uploads'),
      peerKey: () => coord.options.roomKey?.peerKey(),
      chunksFor: _chunks.hashesFor,
      partialFor: (id) => PartialTrack.peek(cache.dir, id),
      acceptUpload: (id, file) async {
        await cache.dir.create(recursive: true);
        final dest = cache.fileFor(id);
        if (!await dest.exists()) await file.copy(dest.path);
        _served[id] = dest;
        unawaited(_publishChunkRoots(coord, {id: dest}));
      },
    );
  }

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
          roomId: s.roomId, roomName: s.roomName, host: host, port: port, hosted: false, at: DateTime.now(), joinKey: joinKey));
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
    _swarm = SwarmDownloader(log: log);
    final libraryFiles = {for (final t in library) t.id: File(t.path)};
    await _startPeerServer(libraryFiles);
    final backend = await backendFactory(log);
    TrackResolver resolver = LibraryTrackResolver(
      library: {for (final t in library) t.id: File(t.path)},
      cache: _cache,
      downloader: _downloader!,
      swarm: _swarm,
      log: log,
    );
    final convert = converterFor?.call(backend);
    if (convert != null) resolver = ConvertingTrackResolver(inner: resolver, convert: convert, log: log);
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
        // Every phone can take over if the coordinator disappears, follow a
        // redirect, and receive the role back (handback); see failover.dart.
        failover: _AppFailover(this, identity),
        recorder: recorderFor?.call(backend),
        peerPort: _peerServer?.port,
        calibrationTracks: FileCalibrationTrackFactory(Directory('${cacheDir.path}/calibration')),
      ),
      connector: webSocketConnector(host, port),
      clock: clock,
      backend: backend,
      resolver: resolver,
      log: log,
    );
    session = s;
    await s.start();
    await hooks.enterRoom(s.state?.roomName ?? 'SyncSphere');
    final warmer = resolver is ConvertingTrackResolver ? resolver : null;
    if (warmer != null) {
      // Decode playlist tracks already on this device ahead of time, so the
      // first play or seek does not wait for it.
      String? warmed;
      _subs.add(s.stateStream.listen((r) {
        final sig = r.playlist.map((t) => t.id).join(',');
        if (sig == warmed) return;
        warmed = sig;
        unawaited(warmer.warm(r.playlist, r.distribution));
      }));
    }
    _subs
      ..add(s.stateStream.listen(_updateNowPlaying))
      ..add(hooks.commands.listen(_onExternalCommand));
  }

  /// Starts this phone's peer file server: complete songs (My music, the
  /// download cache) and songs still being assembled, for other guests.
  /// Requests must carry a token signed with the room's peer key.
  Future<void> _startPeerServer(Map<String, File> libraryFiles) async {
    await _stopPeerServer();
    final cache = _cache;
    final files = TrackFileServer(
      fileForTrack: (id) {
        final lib = libraryFiles[id];
        if (lib != null && lib.existsSync()) return lib;
        final cached = cache.fileFor(id);
        return cached.existsSync() ? cached : null;
      },
      keysForSession: (_) => null,
      nowMs: () {
        final e = session?.estimate;
        final now = clock.nowMicros();
        return (e == null ? now : e.toRemote(now)) ~/ 1000;
      },
      log: log,
      peerKey: () => session?.peerKey,
      chunksFor: _chunks.hashesFor,
      partialFor: (id) => PartialTrack.peek(cache.dir, id),
    );
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      server.listen(files.handle, onError: (Object e) => log.warn('peer.server', '$e'));
      _peerServer = server;
      _peerFiles = files;
    } catch (e) {
      log.warn('peer.server', 'phone-to-phone sharing unavailable: $e');
    }
  }

  Future<void> _stopPeerServer() async {
    final s = _peerServer;
    _peerServer = null;
    _peerFiles = null;
    await s?.close(force: true);
  }

  /// Bytes this phone served to other guests (diagnostics).
  int get bytesSharedWithPeers => _peerFiles?.bytesServed ?? 0;

  void _updateNowPlaying(RoomState r) {
    final tl = r.timeline;
    final String text;
    if (r.calibration != null) {
      text = 'Calibrating…';
    } else {
      final t = r.trackById(tl.trackId);
      text = t == null ? '${r.participants.length} device(s) · nothing playing' : [t.title, if (t.artist != null) t.artist].join(' · ');
    }
    unawaited(hooks.nowPlaying(roomName: r.roomName, text: text, playing: tl.isPlaying));
  }

  void _onExternalCommand(String cmd) {
    final s = session;
    if (s == null) return;
    final action = switch (cmd) {
      'play' => ControlAction.play,
      'pause' => ControlAction.pause,
      'next' => ControlAction.next,
      'previous' => ControlAction.previous,
      _ => null,
    };
    if (action == null) return;
    unawaited(s.control(action).then((ack) {
      if (!ack.accepted) log.warn('notification.control', '$cmd rejected: ${ack.error}');
    }));
  }

  void _cancelSubs() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
  }

  /// Test hook: kills hosting abruptly (no `bye`), as if the app crashed,
  /// so guests exercise failover.
  Future<void> crashForTesting() async {
    _stopWatch();
    _stopChunkRoots();
    _cancelSubs();
    final c = coordinator;
    coordinator = null;
    await c?.abort();
    _beacon?.stop();
    _beacon = null;
    await _server?.close();
    _server = null;
    final s = session;
    session = null;
    await s?.close();
    await _stopPeerServer();
    info = null;
  }

  /// Adds library tracks to the room. The coordinator adds them directly;
  /// a guest allowed to control the music uploads each song to the
  /// coordinator first. [onProgress] reports (done, total) songs. Returns
  /// the error of the first song that could not be added, or null.
  Future<String?> addTracks(List<LibraryTrack> tracks, {void Function(int done, int total)? onProgress}) async {
    final c = coordinator;
    if (c != null) {
      for (final t in tracks) {
        _served[t.id] = File(t.path);
        c.addTrack(t.toTrackInfo());
      }
      onProgress?.call(tracks.length, tracks.length);
      return null;
    }
    final s = session;
    if (s == null) return ControlError.notConnected;
    var done = 0;
    for (final t in tracks) {
      onProgress?.call(done, tracks.length);
      final ack = await s.uploadTrack(File(t.path), t.toTrackInfo());
      if (!ack.accepted) return ack.error ?? 'failed';
      done++;
    }
    onProgress?.call(done, tracks.length);
    return null;
  }

  /// Saves what this device learned (start latency, and the output
  /// calibration, which acoustic calibration may have changed) for next time.
  Future<DeviceIdentity?> persistCalibration() async {
    final s = session;
    final id = _identity;
    if (s == null || id == null) return id;
    final learned = s.engine.startLatencyUs;
    final cal = s.engine.outputCalibrationUs;
    if (learned != id.startLatencyUs || cal != id.outputCalibrationUs) {
      _identity = id.copyWith(startLatencyUs: learned, outputCalibrationUs: cal);
      await store.saveIdentity(_identity!);
    }
    return _identity;
  }

  /// Leaves the party. The original host ends it for everyone ([endParty]);
  /// a temporary host (after failover) hands it to another phone first.
  Future<void> leave({bool endParty = true}) async {
    try {
      await persistCalibration();
    } catch (e) {
      log.warn('room.persist', 'could not save calibration: $e');
    }
    final c = coordinator;
    // A phone that only stepped in for the host hands the party on rather
    // than ending it (planned leadership transfer).
    final passOn = c != null && (promotedByFailover || !endParty);
    var handedOff = false;
    if (passOn) {
      try {
        handedOff = await c.handOff().timeout(const Duration(seconds: 8), onTimeout: () => false);
        if (handedOff) await Future<void>.delayed(const Duration(milliseconds: 600));
      } catch (e) {
        log.warn('room.handoff', 'hand-off failed: $e');
      }
    }
    // Leaving on purpose: no "Rejoin your party" offer afterwards. (A crash
    // or a closed app never gets here, so the offer survives those.)
    final hosted = await store.hostedRoom();
    if (endParty && hosted != null && hosted.roomId == info?.roomId) {
      await store.saveHostedRoom(null);
    }
    _stopWatch();
    _stopChunkRoots();
    _cancelSubs();
    final s = session;
    session = null;
    if (s != null) await s.leave();
    _beacon?.stop();
    _beacon = null;
    coordinator = null;
    if (c != null) {
      if (passOn && !handedOff) {
        // Nobody confirmed the hand-off in time: leave without `bye`, so the
        // other phones fail over and keep the party instead of ending it.
        log.warn('room.handoff', 'hand-off not confirmed; leaving without ending the party');
        await c.abort();
      } else {
        await c.close(reason: 'host left; room closed');
      }
    }
    await _server?.close();
    _server = null;
    _downloader?.close();
    _downloader = null;
    _swarm?.close();
    _swarm = null;
    await _stopPeerServer();
    info = null;
    promotedByFailover = false;
    await hooks.leaveRoom();
  }
}

class _AppFailover implements FailoverDelegate {
  final RoomService service;
  final DeviceIdentity identity;
  _AppFailover(this.service, this.identity);

  @override
  int get failoverPort => service.failoverPort;

  @override
  Future<Connector> promote(PromotionRequest request) => service._promote(request, identity);

  @override
  Connector connectorFor(String endpoint) {
    final i = endpoint.lastIndexOf(':');
    final port = int.tryParse(endpoint.substring(i + 1)) ?? kDefaultRoomPort;
    return webSocketConnector(endpoint.substring(0, i), port);
  }
}
