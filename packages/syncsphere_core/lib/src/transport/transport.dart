/// Transport abstraction. The protocol layer only needs ordered, reliable,
/// message-framed, bidirectional links; WebSockets over TCP provide that in
/// production and [MemoryNetwork] provides it (with injected latency, jitter,
/// loss-induced delay and partitions) in tests and simulations.
library;

import 'dart:async';

abstract class MessageConnection {
  /// Human-readable remote endpoint (address:port) for logs and rate limits.
  String get remoteAddress;

  /// Inbound text frames. Single subscription. Closes when the link closes.
  Stream<String> get incoming;

  /// Sends a text frame. Frames sent after close are dropped.
  void send(String frame);

  bool get isOpen;

  Future<void> close([String reason = 'closed']);

  /// Completes when the link is closed from either side.
  Future<void> get done;
}

/// Server side: yields accepted connections.
abstract class ConnectionAcceptor {
  Stream<MessageConnection> get connections;
  Future<void> close();
}

/// Client side: opens a new connection to the coordinator.
typedef Connector = Future<MessageConnection> Function();
