/// Production transport: WebSockets (RFC 6455) over TCP via `dart:io`.
///
/// One `HttpServer` on the coordinator serves both the control channel
/// (`/ws`) and LAN track delivery (`/tracks/...`), so a single port has to be
/// reachable. Discovery runs separately over UDP.
library;

import 'dart:async';
import 'dart:io';

import 'transport.dart';

class WebSocketMessageConnection implements MessageConnection {
  final WebSocket _ws;
  @override
  final String remoteAddress;
  late final Stream<String> _incoming;
  bool _open = true;

  WebSocketMessageConnection(this._ws, this.remoteAddress) {
    _incoming = _ws
        .where((e) {
          if (e is String) return true;
          // Binary frames are not part of the protocol: drop the link.
          close('binary frame');
          return false;
        })
        .cast<String>();
    _ws.done.whenComplete(() => _open = false);
  }

  @override
  Stream<String> get incoming => _incoming;

  @override
  bool get isOpen => _open && _ws.readyState == WebSocket.open;

  @override
  void send(String frame) {
    if (!isOpen) return;
    _ws.add(frame);
  }

  @override
  Future<void> close([String reason = 'closed']) async {
    if (!_open) return;
    _open = false;
    final r = reason.length > 100 ? reason.substring(0, 100) : reason;
    await _ws.close(WebSocketStatus.normalClosure, r);
  }

  @override
  Future<void> get done => _ws.done;
}

/// HTTP + WebSocket server for the coordinator.
class WebSocketServer implements ConnectionAcceptor {
  final HttpServer _server;
  final StreamController<MessageConnection> _connections = StreamController();
  final Future<void> Function(HttpRequest request)? httpHandler;
  final void Function(Object error, StackTrace st)? onError;

  WebSocketServer._(this._server, this.httpHandler, this.onError) {
    _server.listen(_handle, onError: (Object e, StackTrace st) => onError?.call(e, st));
  }

  /// Binds on [address]:[port] (port 0 picks a free port).
  static Future<WebSocketServer> bind({
    Object address = '0.0.0.0',
    int port = 0,
    Future<void> Function(HttpRequest request)? httpHandler,
    void Function(Object error, StackTrace st)? onError,
  }) async {
    final s = await HttpServer.bind(address, port, shared: false);
    s.idleTimeout = const Duration(seconds: 30);
    return WebSocketServer._(s, httpHandler, onError);
  }

  int get port => _server.port;
  InternetAddress get address => _server.address;

  @override
  Stream<MessageConnection> get connections => _connections.stream;

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.uri.path == '/ws') {
        if (!WebSocketTransformer.isUpgradeRequest(req)) {
          req.response.statusCode = HttpStatus.badRequest;
          await req.response.close();
          return;
        }
        final remote = req.connectionInfo == null
            ? 'unknown'
            : '${req.connectionInfo!.remoteAddress.address}:${req.connectionInfo!.remotePort}';
        // Compression off: avoids decompression bombs and per-frame CPU cost.
        // Ownership passes to WebSocketMessageConnection, which closes it.
        // ignore: close_sinks
        final ws = await WebSocketTransformer.upgrade(req,
            compression: CompressionOptions.compressionOff);
        if (_connections.isClosed) {
          await ws.close(WebSocketStatus.goingAway);
          return;
        }
        _connections.add(WebSocketMessageConnection(ws, remote));
        return;
      }
      final h = httpHandler;
      if (h != null) {
        await h(req);
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    } catch (e, st) {
      onError?.call(e, st);
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {
        // Response already committed or socket gone; nothing more to do.
      }
    }
  }

  @override
  Future<void> close() async {
    await _connections.close();
    await _server.close(force: true);
  }
}

/// Connector for participants.
Connector webSocketConnector(String host, int port,
    {Duration timeout = const Duration(seconds: 5)}) {
  return () async {
    // Ownership passes to WebSocketMessageConnection, which closes it.
    // ignore: close_sinks
    final ws = await WebSocket.connect('ws://$host:$port/ws',
            compression: CompressionOptions.compressionOff)
        .timeout(timeout);
    return WebSocketMessageConnection(ws, '$host:$port');
  };
}
