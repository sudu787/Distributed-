/// Wire framing: `<tag>.<json>` where `json` is the envelope
/// `{"v":1,"t":type,"s":seq,"b":body}` and `tag` is a truncated HMAC over the
/// exact JSON bytes using the sender's direction key, or `-` for the
/// unauthenticated handshake frames.
///
/// Per-direction sequence numbers must strictly increase. Because transport
/// connections are ordered (TCP/WebSocket), any non-increasing sequence on an
/// authenticated channel indicates replay or injection and is rejected.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../config/sync_config.dart';
import 'auth.dart';
import 'messages.dart';
import 'reader.dart';

const int kEnvelopeVersion = 1;

/// Message types that may travel before session keys exist.
const Set<String> kHandshakeTypes = {
  HelloMsg.kType,
  ChallengeMsg.kType,
  AuthMsg.kType,
  RejectMsg.kType,
};

class FrameCodec {
  final ProtocolLimits limits;
  Uint8List? _sendKey;
  Uint8List? _recvKey;
  int _sendSeq = 0;
  int _recvSeq = 0;

  FrameCodec({this.limits = const ProtocolLimits()});

  bool get isAuthenticated => _sendKey != null && _recvKey != null;

  /// Client side, between sending `auth` and receiving `welcome`: the
  /// coordinator answers a failed authentication with an *unauthenticated*
  /// `reject` (it has no session key for a client that failed to prove the
  /// room key). Only `reject` is accepted this way, nothing else.
  bool allowPlainReject = false;

  /// Activates per-message authentication for both directions.
  void activate({required Uint8List sendKey, required Uint8List recvKey}) {
    _sendKey = sendKey;
    _recvKey = recvKey;
  }

  String encode(Message m) {
    final json = jsonEncode({
      'v': kEnvelopeVersion,
      't': m.type,
      's': ++_sendSeq,
      'b': m.toBody(),
    });
    final key = _sendKey;
    if (key == null && !kHandshakeTypes.contains(m.type)) {
      throw StateError('cannot send ${m.type} before authentication');
    }
    final tag = key == null ? '-' : macTag(key, utf8.encode(json));
    return '$tag.$json';
  }

  /// Decodes and authenticates one frame. Throws [ProtocolException] on any
  /// problem; the caller decides whether to drop the frame or the link.
  Message decode(String frame) {
    if (frame.length > limits.maxFrameBytes) {
      throw ProtocolException('frame_too_large',
          'frame of ${frame.length} chars exceeds ${limits.maxFrameBytes}');
    }
    final dot = frame.indexOf('.');
    if (dot <= 0 || dot > 40) {
      throw const ProtocolException('malformed', 'missing frame tag');
    }
    final tag = frame.substring(0, dot);
    final json = frame.substring(dot + 1);

    var key = _recvKey;
    var plainReject = false;
    if (key != null && tag == '-' && allowPlainReject) {
      plainReject = true;
      key = null;
    }
    if (key != null) {
      if (!constantTimeEquals(tag, macTag(key, utf8.encode(json)))) {
        throw const ProtocolException('bad_mac', 'frame authentication failed');
      }
    } else if (tag != '-') {
      throw const ProtocolException('malformed', 'unexpected tag before auth');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      throw ProtocolException('malformed', 'invalid JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw const ProtocolException('malformed', 'envelope is not an object');
    }
    final r = Reader(decoded.cast<String, Object?>(), 'envelope');
    final v = r.integer('v');
    if (v != kEnvelopeVersion) {
      throw ProtocolException('unsupported_version', 'envelope version $v');
    }
    final type = r.string('t', maxLength: 32);
    final seq = r.integer('s', min: 1);
    if (seq <= _recvSeq) {
      throw ProtocolException(
          'replay', 'sequence $seq not after $_recvSeq (duplicate or replay)');
    }
    if (key == null && !kHandshakeTypes.contains(type)) {
      throw ProtocolException('unauthenticated', '$type before authentication');
    }
    if (plainReject && type != RejectMsg.kType) {
      throw const ProtocolException('bad_mac', 'only reject may be unauthenticated here');
    }
    final body = r.map('b');
    final msg = Message.parse(type, body, limits: limits);
    _recvSeq = seq;
    return msg;
  }
}
