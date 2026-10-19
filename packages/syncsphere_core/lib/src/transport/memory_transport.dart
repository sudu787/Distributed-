/// In-process network with configurable impairments, used by integration
/// tests and the virtual-time simulator. All delays are realised with
/// `Timer`, so under `fake_async` they run in virtual time.
///
/// Semantics follow TCP rather than UDP: delivery is reliable and ordered
/// per direction. Packet loss is modelled as retransmission delay (each lost
/// transmission adds one retransmission timeout), which is what a WebSocket
/// application observes on a lossy link. Partitions hold traffic (and the
/// close notification) until healed, like a TCP connection whose peer has
/// silently vanished.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import '../time/clock.dart';
import 'transport.dart';

/// Per-direction delay model.
class LinkProfile {
  /// Minimum one-way delay.
  final Duration base;

  /// Additional random delay drawn from an exponential distribution with
  /// this mean (heavy-ish tail, typical for Wi-Fi contention).
  final Duration jitterMean;

  /// Probability that a transmission is lost (retransmitted after [rto]).
  final double lossRate;
  final Duration rto;

  /// Probability of a large delay spike (e.g. Wi-Fi power-save buffering).
  final double spikeRate;
  final Duration spike;

  /// Link-wide stalls (roaming, deep power save, interference): on average
  /// one every [stallMeanGap] (exponential gaps; null = never), each
  /// lasting between [stallMin] and [stallMax]. Nothing is delivered in
  /// either direction during a stall; frames are held, not lost (TCP).
  /// Read from the uplink profile.
  final Duration? stallMeanGap;
  final Duration stallMin;
  final Duration stallMax;

  const LinkProfile({
    this.base = const Duration(milliseconds: 1),
    this.jitterMean = Duration.zero,
    this.lossRate = 0,
    this.rto = const Duration(milliseconds: 200),
    this.spikeRate = 0,
    this.spike = const Duration(milliseconds: 100),
    this.stallMeanGap,
    this.stallMin = const Duration(seconds: 2),
    this.stallMax = const Duration(seconds: 5),
  });

  int sampleMicros(Random rnd) {
    var us = base.inMicroseconds;
    if (jitterMean > Duration.zero) {
      final u = rnd.nextDouble();
      us += (-log(1 - u) * jitterMean.inMicroseconds).round();
    }
    if (spikeRate > 0 && rnd.nextDouble() < spikeRate) {
      us += (rnd.nextDouble() * spike.inMicroseconds).round();
    }
    var rto = this.rto.inMicroseconds;
    while (lossRate > 0 && rnd.nextDouble() < lossRate) {
      us += rto;
      rto = min(rto * 2, 3000000); // exponential RTO backoff, capped
    }
    return us;
  }
}

/// Bidirectional link between a client and a server endpoint.
class Link {
  LinkProfile uplink; // client → server
  LinkProfile downlink; // server → client
  bool _partitioned = false;
  final List<void Function()> _onHeal = [];

  Link({required this.uplink, required this.downlink});

  bool get partitioned => _partitioned;

  // Stall windows [start, end) in µs, generated lazily and in order.
  final List<(int, int)> _stalls = [];
  int _stallHorizonUs = 0;

  /// The time a frame due at [atUs] is actually delivered: the end of the
  /// stall covering [atUs], if any.
  int deliveryTime(int atUs, Random rnd) {
    final gap = uplink.stallMeanGap;
    if (gap == null) return atUs;
    if (_stalls.isEmpty && _stallHorizonUs == 0) _stallHorizonUs = atUs; // first frame: start the schedule now
    while (_stallHorizonUs <= atUs) {
      final start = _stallHorizonUs + (-log(1 - rnd.nextDouble()) * gap.inMicroseconds).round();
      final len = uplink.stallMin.inMicroseconds +
          (rnd.nextDouble() * (uplink.stallMax.inMicroseconds - uplink.stallMin.inMicroseconds)).round();
      _stalls.add((start, start + len));
      _stallHorizonUs = start + len;
    }
    for (final (s, e) in _stalls) {
      if (atUs >= s && atUs < e) return e;
    }
    return atUs;
  }

  /// Stall windows generated so far (for reports).
  List<(int, int)> get stalls => List.unmodifiable(_stalls);

  void partition() => _partitioned = true;

  void heal() {
    _partitioned = false;
    final cbs = List.of(_onHeal);
    _onHeal.clear();
    for (final cb in cbs) {
      cb();
    }
  }
}

class _Direction {
  final Queue<(String?, int)> held = Queue(); // (frame or null=close, sendTime)
  int lastDeliveryUs = 0;
}

class MemoryConnection implements MessageConnection {
  @override
  final String remoteAddress;
  final MemoryNetwork _net;
  final Link link;
  final bool _isClient;
  late MemoryConnection _peer;
  final StreamController<String> _in = StreamController<String>();
  final Completer<void> _done = Completer<void>();
  final _Direction _out = _Direction();
  bool _open = true;
  bool _peerClosedDelivered = false;

  MemoryConnection._(this._net, this.link, this._isClient, this.remoteAddress);

  @override
  Stream<String> get incoming => _in.stream;

  @override
  bool get isOpen => _open;

  @override
  Future<void> get done => _done.future;

  LinkProfile get _profile => _isClient ? link.uplink : link.downlink;

  @override
  void send(String frame) {
    if (!_open) return;
    _net.bytesSent += frame.length;
    _net.framesSent++;
    _transmit(frame);
  }

  void _transmit(String? frame) {
    if (link.partitioned) {
      _out.held.add((frame, _net.clock.nowMicros()));
      if (_out.held.length == 1) link._onHeal.add(_flushHeld);
      return;
    }
    final now = _net.clock.nowMicros();
    var at = link.deliveryTime(now + _profile.sampleMicros(_net.random), _net.random);
    if (at < _out.lastDeliveryUs) at = _out.lastDeliveryUs; // keep order
    _out.lastDeliveryUs = at;
    Timer(Duration(microseconds: at - now), () => _peer._deliver(frame));
  }

  void _flushHeld() {
    while (_out.held.isNotEmpty) {
      final (frame, _) = _out.held.removeFirst();
      _transmit(frame);
    }
  }

  void _deliver(String? frame) {
    if (_peerClosedDelivered) return;
    if (frame == null) {
      _peerClosedDelivered = true;
      _shutdown();
      return;
    }
    if (_open && !_in.isClosed) _in.add(frame);
  }

  @override
  Future<void> close([String reason = 'closed']) async {
    if (!_open) return;
    _transmit(null); // FIN travels like data
    _shutdown();
  }

  /// Abrupt failure (process killed / radio lost): no FIN is sent; the peer
  /// must detect the failure by timeout.
  void kill() => _shutdown();

  void _shutdown() {
    if (!_open) return;
    _open = false;
    if (!_in.isClosed) _in.close();
    if (!_done.isCompleted) _done.complete();
  }
}

class MemoryAcceptor implements ConnectionAcceptor {
  final String address;
  final MemoryNetwork _net;
  final StreamController<MessageConnection> _c = StreamController();
  MemoryAcceptor._(this._net, this.address);

  @override
  Stream<MessageConnection> get connections => _c.stream;

  @override
  Future<void> close() async {
    _net._servers.remove(address);
    await _c.close();
  }
}

class MemoryNetwork {
  final MonotonicClock clock;
  final Random random;
  final Map<String, MemoryAcceptor> _servers = {};
  final List<MemoryConnection> _connections = [];
  int bytesSent = 0;
  int framesSent = 0;

  MemoryNetwork({required this.clock, Random? random}) : random = random ?? Random(1);

  MemoryAcceptor listen(String address) {
    if (_servers.containsKey(address)) {
      throw StateError('address in use: $address');
    }
    return _servers[address] = MemoryAcceptor._(this, address);
  }

  /// Opens a connection from [clientName] to [address] over [link]. The
  /// connect itself costs one round trip.
  Future<MessageConnection> connect(String clientName, String address, Link link) async {
    final rtt = link.uplink.sampleMicros(random) + link.downlink.sampleMicros(random);
    await Future<void>.delayed(Duration(microseconds: rtt));
    if (link.partitioned) {
      // A SYN that never gets answered: time out like a TCP connect would.
      await Future<void>.delayed(const Duration(seconds: 3));
      throw const SocketLikeException('connect timeout (partitioned)');
    }
    final server = _servers[address];
    if (server == null || server._c.isClosed) {
      throw SocketLikeException('connection refused: $address');
    }
    final client = MemoryConnection._(this, link, true, address);
    final srv = MemoryConnection._(this, link, false, clientName);
    client._peer = srv;
    srv._peer = client;
    _connections
      ..add(client)
      ..add(srv);
    server._c.add(srv);
    return client;
  }

  Connector connector(String clientName, String address, Link link) =>
      () => connect(clientName, address, link);

  /// Abruptly kills every open connection whose remote side is [address]
  /// (simulates the coordinator process dying).
  void killServer(String address) {
    for (final c in _connections) {
      if (c.remoteAddress == address || c._peer.remoteAddress == address) {
        c.kill();
      }
    }
    _servers.remove(address)?._c.close();
  }
}

class SocketLikeException implements Exception {
  final String message;
  const SocketLikeException(this.message);
  @override
  String toString() => 'SocketLikeException: $message';
}
