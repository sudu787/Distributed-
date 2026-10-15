/// Local-network room discovery via UDP broadcast beacons.
///
/// Evaluation (details in `docs/architecture.md`): mDNS/DNS-SD is the
/// standards-based choice and is used on Android through `NsdManager` where
/// available, but multicast is frequently filtered on consumer APs and
/// hotspots and needs a `MulticastLock`. A plain UDP broadcast beacon works
/// on more networks, is trivial to implement identically on every platform,
/// and is what this module provides. Neither works under AP client
/// isolation; manual `host:port` entry is always available as a fallback.
///
/// Beacons are unauthenticated hints: they contain no secrets, and joining
/// still requires the room key. A spoofed beacon can at most point a user at
/// a coordinator that cannot authenticate (mutual auth fails).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int kDiscoveryPort = 47801;
const String kBeaconMagic = 'syncsphere';

class RoomBeacon {
  final String roomId;
  final String roomName;
  final String coordinatorId;
  final int coordinatorEpoch;
  final int port;
  final int protocol;
  final int participants;

  /// Filled in by the listener from the datagram's source address.
  final String? host;
  final DateTime? seenAt;

  const RoomBeacon({
    required this.roomId,
    required this.roomName,
    required this.coordinatorId,
    required this.coordinatorEpoch,
    required this.port,
    this.protocol = 1,
    this.participants = 0,
    this.host,
    this.seenAt,
  });

  List<int> encode() => utf8.encode(jsonEncode({
        'app': kBeaconMagic,
        'v': protocol,
        'room': roomId,
        'name': roomName,
        'coord': coordinatorId,
        'epoch': coordinatorEpoch,
        'port': port,
        'n': participants,
      }));

  /// Parses a beacon; returns null for anything that is not a valid beacon.
  static RoomBeacon? decode(List<int> data, String host, DateTime now) {
    if (data.length > 1024) return null;
    try {
      final j = jsonDecode(utf8.decode(data));
      if (j is! Map || j['app'] != kBeaconMagic) return null;
      final port = j['port'];
      final room = j['room'], name = j['name'], coord = j['coord'];
      if (port is! int || port <= 0 || port > 65535) return null;
      if (room is! String || room.isEmpty || room.length > 64) return null;
      if (name is! String || name.length > 64) return null;
      if (coord is! String || coord.length > 64) return null;
      final epoch = j['epoch'] is int ? j['epoch'] as int : 1;
      final v = j['v'] is int ? j['v'] as int : 1;
      final n = j['n'] is int ? j['n'] as int : 0;
      return RoomBeacon(
        roomId: room,
        roomName: name,
        coordinatorId: coord,
        coordinatorEpoch: epoch,
        port: port,
        protocol: v,
        participants: n,
        host: host,
        seenAt: now,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Periodically broadcasts a beacon for a hosted room.
class BeaconBroadcaster {
  final RoomBeacon Function() beacon;
  final Duration interval;
  final int port;
  RawDatagramSocket? _socket;
  Timer? _timer;

  BeaconBroadcaster({required this.beacon, this.interval = const Duration(seconds: 1), this.port = kDiscoveryPort});

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket!.broadcastEnabled = true;
    _timer = Timer.periodic(interval, (_) => _send());
    await _send();
  }

  Future<void> _send() async {
    final s = _socket;
    if (s == null) return;
    final data = beacon().encode();
    for (final target in await broadcastTargets()) {
      try {
        s.send(data, target, port);
      } on SocketException {
        // Interface went away or broadcast not permitted on it; try others.
      }
    }
  }

  void stop() {
    _timer?.cancel();
    _socket?.close();
    _socket = null;
  }
}

/// Broadcast destinations: the limited broadcast address plus the /24
/// directed broadcast of each IPv4 interface. (`dart:io` does not expose
/// netmasks; /24 matches typical home routers and Android hotspots, and the
/// limited broadcast covers the rest where the OS routes it.)
Future<List<InternetAddress>> broadcastTargets() async {
  final out = <InternetAddress>[InternetAddress('255.255.255.255')];
  try {
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in ni.addresses) {
        if (a.isLoopback) continue;
        final p = a.rawAddress;
        out.add(InternetAddress.fromRawAddress(Uint8List.fromList([p[0], p[1], p[2], 255])));
      }
    }
  } on SocketException {
    // Interface enumeration failed; limited broadcast still works.
  }
  return out;
}

/// Listens for beacons and maintains the set of live rooms.
class RoomDiscovery {
  final int port;
  final Duration ttl;
  RawDatagramSocket? _socket;
  final Map<String, RoomBeacon> _rooms = {};
  final StreamController<List<RoomBeacon>> _ctl = StreamController.broadcast();
  Timer? _expiry;

  RoomDiscovery({this.port = kDiscoveryPort, this.ttl = const Duration(seconds: 5)});

  Stream<List<RoomBeacon>> get rooms => _ctl.stream;
  List<RoomBeacon> get current => _rooms.values.toList();

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
    _socket!.broadcastEnabled = true;
    _socket!.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final dg = _socket?.receive();
      if (dg == null) return;
      final b = RoomBeacon.decode(dg.data, dg.address.address, DateTime.now());
      if (b == null) return;
      final key = '${b.roomId}@${b.host}:${b.port}';
      final isNew = !_rooms.containsKey(key);
      _rooms[key] = b;
      if (isNew) _emit();
    });
    _expiry = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      final before = _rooms.length;
      _rooms.removeWhere((_, b) => now.difference(b.seenAt!) > ttl);
      if (_rooms.length != before) _emit();
    });
  }

  void _emit() {
    if (!_ctl.isClosed) _ctl.add(current);
  }

  Future<void> stop() async {
    _expiry?.cancel();
    _socket?.close();
    await _ctl.close();
  }
}
