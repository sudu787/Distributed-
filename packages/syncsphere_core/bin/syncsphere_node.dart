/// Headless SyncSphere node.
///
/// Runs a coordinator (`host`) or a participant (`join`) on any machine with
/// the Dart SDK, e.g. a laptop on the same Wi-Fi acting as a dedicated
/// coordinator, or a protocol/latency probe during real-device benchmarks.
/// Audio output is a null sink: this node follows the timeline but renders
/// no sound.
///
///     dart run bin/syncsphere_node.dart host --name "Living room" \
///         --track ~/Music/song.mp3 --port 47800
///     dart run bin/syncsphere_node.dart join --host 192.168.1.20 \
///         --port 47800 --key ABCD-1234 --play
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Print debug events');
  final host = parser.addCommand('host')
    ..addOption('name', defaultsTo: 'SyncSphere room')
    ..addOption('port', defaultsTo: '47800')
    ..addOption('key', help: 'Join key (generated if omitted)')
    ..addMultiOption('track', help: 'Audio file to offer (repeatable)')
    ..addOption('distribution', allowed: ['localOnly', 'auto', 'lanOnly'], defaultsTo: 'auto')
    ..addFlag('open-control', help: 'New members may control playback', defaultsTo: false)
    ..addFlag('beacon', help: 'Broadcast UDP discovery beacons', defaultsTo: true);
  final join = parser.addCommand('join')
    ..addOption('host', mandatory: true)
    ..addOption('port', defaultsTo: '47800')
    ..addOption('key', mandatory: true)
    ..addOption('name', defaultsTo: Platform.localHostname)
    ..addOption('cache', defaultsTo: '${Directory.systemTemp.path}/syncsphere-cache')
    ..addMultiOption('track', help: 'Local audio file (repeatable)')
    ..addFlag('play', help: 'Request playback after joining', defaultsTo: false)
    ..addOption('report-json', help: 'Append diagnostics as JSON lines to this file');
  parser.addCommand('discover');

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exitCode = 64;
    return;
  }
  if (args['help'] as bool || args.command == null) {
    stdout.writeln('usage: syncsphere_node <host|join|discover> [options]\n');
    stdout.writeln('host:\n${host.usage}\n\njoin:\n${join.usage}');
    return;
  }
  final verbose = args['verbose'] as bool;
  final clock = SystemMonotonicClock.instance;
  void printer(String src, SyncEvent e) {
    if (verbose || e.level.index >= EventLevel.info.index) stdout.writeln('${src.padRight(12)} $e');
  }

  switch (args.command!.name) {
    case 'host':
      await _host(args.command!, clock, printer);
    case 'join':
      await _join(args.command!, clock, printer);
    case 'discover':
      final d = RoomDiscovery();
      await d.start();
      stdout.writeln('listening for rooms on UDP $kDiscoveryPort (Ctrl+C to stop)');
      d.rooms.listen((rooms) {
        for (final r in rooms) {
          stdout.writeln('  ${r.roomName}  room=${r.roomId}  ${r.host}:${r.port}  epoch=${r.coordinatorEpoch}');
        }
      });
      await ProcessSignal.sigint.watch().first;
      await d.stop();
  }
}

Future<Map<String, (File, TrackInfo)>> _index(List<String> paths) async {
  final hasher = TrackHasher();
  final out = <String, (File, TrackInfo)>{};
  for (final p in paths) {
    final f = File(p);
    final h = await hasher.hash(f);
    final name = f.uri.pathSegments.last;
    out[h.sha256] = (f, TrackInfo(id: h.sha256, title: name, sizeBytes: h.size));
    stdout.writeln('indexed $name  sha256=${h.sha256.substring(0, 16)}…  ${h.size} bytes');
  }
  return out;
}

Future<void> _host(ArgResults a, MonotonicClock clock, void Function(String, SyncEvent) printer) async {
  final key = a['key'] as String? ?? generateJoinKey();
  final roomId = newId(6);
  final deviceId = 'node-${newId(6)}';
  final tracks = await _index(a['track'] as List<String>);
  final log = EventLog(clock: clock, source: 'coordinator', printer: printer);
  final coord = RoomCoordinator(
    options: CoordinatorOptions(
      roomId: roomId,
      roomName: a['name'] as String,
      coordinatorId: deviceId,
      joinKey: key,
      defaultRole: (a['open-control'] as bool) ? ParticipantRole.controller : ParticipantRole.listener,
      distribution: DistributionMode.values.byName(a['distribution'] as String),
    ),
    clock: clock,
    log: log,
  );
  coord.setPlaylist([for (final t in tracks.values) t.$2]);
  final files = TrackFileServer(
    fileForTrack: (id) => tracks[id]?.$1,
    keysForSession: coord.transferKeysForSession,
    nowMs: () => clock.nowMicros() ~/ 1000,
    log: log,
  );
  final server = await WebSocketServer.bind(
    port: int.parse(a['port'] as String),
    httpHandler: files.handle,
    onError: (e, st) => log.error('server', '$e'),
  );
  coord.serve(server);
  coord.start();
  BeaconBroadcaster? beacon;
  if (a['beacon'] as bool) {
    beacon = BeaconBroadcaster(
      beacon: () => RoomBeacon(
        roomId: roomId,
        roomName: coord.state.roomName,
        coordinatorId: deviceId,
        coordinatorEpoch: coord.state.coordinatorEpoch,
        port: server.port,
        participants: coord.state.participants.length,
      ),
    );
    await beacon.start();
  }
  final addrs = <String>[];
  for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    addrs.addAll(ni.addresses.where((x) => !x.isLoopback).map((x) => x.address));
  }
  stdout.writeln('\nRoom "${coord.state.roomName}" (id $roomId) is up.');
  stdout.writeln('  join key : ${formatJoinKey(key)}');
  stdout.writeln('  address  : ${addrs.isEmpty ? '127.0.0.1' : addrs.join(', ')} port ${server.port}');
  stdout.writeln('  (this headless coordinator plays no audio itself)\n');
  coord.diagnosticsStream.listen((d) {
    if (d.participants.isEmpty) return;
    final parts = d.participants
        .map((p) => '${p.deviceId}:${p.errorUs == null ? '-' : '${(p.errorUs! / 1000).toStringAsFixed(1)}ms'}/${p.mode.name}')
        .join('  ');
    stdout.writeln('diag  spread=${d.maxPairwiseErrorUs == null ? '-' : '${(d.maxPairwiseErrorUs! / 1000).toStringAsFixed(1)}ms'} (est.)  $parts');
  });
  await ProcessSignal.sigint.watch().first;
  beacon?.stop();
  await coord.close();
  await server.close();
}

Future<void> _join(ArgResults a, MonotonicClock clock, void Function(String, SyncEvent) printer) async {
  final hostAddr = a['host'] as String;
  final port = int.parse(a['port'] as String);
  final name = a['name'] as String;
  final tracks = await _index(a['track'] as List<String>);
  final log = EventLog(clock: clock, source: name, printer: printer);
  final downloader = TrackDownloader(log: log);
  final session = ParticipantSession(
    options: ParticipantOptions(
      deviceId: 'node-${newId(6)}',
      displayName: name,
      platform: Platform.operatingSystem,
      joinKey: a['key'] as String,
      transferBase: Uri.parse('http://$hostAddr:$port'),
    ),
    connector: webSocketConnector(hostAddr, port),
    clock: clock,
    backend: NullAudioBackend(clock.nowMicros),
    resolver: LibraryTrackResolver(
      library: {for (final e in tracks.entries) e.key: e.value.$1},
      cache: TrackCache(Directory(a['cache'] as String)),
      downloader: downloader,
      log: log,
    ),
    log: log,
  );
  IOSink? report;
  if (a['report-json'] != null) report = File(a['report-json'] as String).openWrite(mode: FileMode.append);
  try {
    await session.start();
  } on SessionFailure catch (f) {
    stderr.writeln('could not join: ${f.code} — ${f.message}');
    exitCode = 1;
    return;
  }
  stdout.writeln('joined as ${session.role?.name}');
  if (a['play'] as bool) {
    final ack = await session.control(ControlAction.play);
    stdout.writeln(ack.accepted ? 'play requested' : 'play refused: ${ack.error}');
  }
  final t = Timer.periodic(const Duration(seconds: 2), (_) {
    final e = session.estimate;
    final s = session.engine.status;
    final line = {
      'phase': session.phase.name,
      'offsetUs': e?.offsetMicros.round(),
      'uncertaintyUs': e?.uncertaintyAt(clock.nowMicros()).round(),
      'rttP95Us': session.rttP95Us,
      'mode': s.mode.name,
      'errorUs': s.lastErrorUs,
      'gen': s.activeGeneration,
    };
    stdout.writeln('status ${jsonEncode(line)}');
    report?.writeln(jsonEncode({'t': DateTime.now().toIso8601String(), ...line}));
  });
  await ProcessSignal.sigint.watch().first;
  t.cancel();
  await session.leave();
  downloader.close();
  await report?.close();
}
