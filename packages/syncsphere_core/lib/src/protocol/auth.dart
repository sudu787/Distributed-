/// Room authentication and message integrity.
///
/// Threat model summary (full version in `docs/threat-model.md`): devices on
/// the same Wi-Fi/hotspot are *not* trusted. A room is protected by a shared
/// join key shown on the host. The key never crosses the network; peers
/// prove knowledge of it with HMAC-SHA256 over fresh nonces, then
/// authenticate every frame with per-direction session keys. This gives
/// authentication, integrity and replay protection, but **not
/// confidentiality** (frames are readable by anyone on the LAN).
///
/// Handshake (client first, so an unauthenticated client never receives
/// anything it could brute-force offline):
///
///     C → S  hello      {deviceId, clientNonce, ...}
///     S → C  challenge  {roomId, serverNonce, kdfIterations}
///     C → S  auth       {proof = HMAC(K, "c|" ctx)}
///     S → C  welcome    {serverProof = HMAC(K, "s|" ctx), ...}   (MAC'd)
///
/// where `K = PBKDF2-HMAC-SHA256(joinKey, "syncsphere-v1|" roomId, iters)`
/// and `ctx = roomId|deviceId|clientNonce|serverNonce`.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Default PBKDF2 iteration count. Slows offline guessing of short join keys
/// by this factor while costing well under a second on a phone.
const int kDefaultKdfIterations = 60000;

final Random _secureRandom = Random.secure();

Uint8List randomBytes(int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = _secureRandom.nextInt(256);
  }
  return b;
}

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64(String s) {
  final pad = (4 - s.length % 4) % 4;
  return base64Url.decode(s + '=' * pad);
}

String newNonce() => b64(randomBytes(18));

/// Random identifier suitable for session and device ids.
String newId([int bytes = 12]) => b64(randomBytes(bytes));

/// Crockford base32 alphabet (no I, L, O, U) — unambiguous when read aloud
/// or typed.
const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Generates a human-typable join key: [length] Crockford-base32 characters
/// (5 bits each). 8 chars = 40 bits; use 26 chars (130 bits) when the key is
/// transferred by QR code or copy/paste on an untrusted network.
String generateJoinKey({int length = 8}) {
  final sb = StringBuffer();
  for (var i = 0; i < length; i++) {
    sb.write(_crockford[_secureRandom.nextInt(32)]);
  }
  return sb.toString();
}

/// Normalises user input: uppercase, strips spaces/dashes, maps the
/// ambiguous letters Crockford allows (I/L → 1, O → 0).
String normalizeJoinKey(String input) {
  final up = input.toUpperCase().replaceAll(RegExp(r'[\s\-_]'), '');
  return up.replaceAll('I', '1').replaceAll('L', '1').replaceAll('O', '0');
}

String formatJoinKey(String key) {
  final k = normalizeJoinKey(key);
  final parts = <String>[];
  for (var i = 0; i < k.length; i += 4) {
    parts.add(k.substring(i, min(i + 4, k.length)));
  }
  return parts.join('-');
}

/// PBKDF2-HMAC-SHA256 producing one 32-byte block.
Uint8List pbkdf2Sha256(List<int> password, List<int> salt, int iterations) {
  if (iterations < 1) throw ArgumentError.value(iterations, 'iterations');
  final hmac = Hmac(sha256, password);
  final block = Uint8List.fromList([...salt, 0, 0, 0, 1]);
  var u = hmac.convert(block).bytes;
  final out = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

/// Derived room key. Compute once per (room, join key) and reuse.
class RoomKey {
  final String roomId;
  final Uint8List _k;
  final int iterations;

  RoomKey._(this.roomId, this._k, this.iterations);

  factory RoomKey.derive({
    required String roomId,
    required String joinKey,
    int iterations = kDefaultKdfIterations,
  }) {
    final pw = utf8.encode(normalizeJoinKey(joinKey));
    final salt = utf8.encode('syncsphere-v1|$roomId');
    return RoomKey._(roomId, pbkdf2Sha256(pw, salt, iterations), iterations);
  }

  List<int> _mac(String label, String ctx) =>
      Hmac(sha256, _k).convert(utf8.encode('$label|$ctx')).bytes;

  static String _ctx(String roomId, String deviceId, String cn, String sn) =>
      '$roomId|$deviceId|$cn|$sn';

  /// Room-wide key for phone-to-phone chunk transfers: every member knows
  /// it (it is derived from the join key), so any member can verify any
  /// other member's request. Grants nothing beyond reading the room's songs.
  List<int> peerKey() => _mac('peer', roomId);

  String clientProof(String deviceId, String clientNonce, String serverNonce) =>
      b64(_mac('c', _ctx(roomId, deviceId, clientNonce, serverNonce)));

  String serverProof(String deviceId, String clientNonce, String serverNonce) =>
      b64(_mac('s', _ctx(roomId, deviceId, clientNonce, serverNonce)));

  SessionKeys sessionKeys(String deviceId, String clientNonce, String serverNonce) {
    final master = _mac('k', _ctx(roomId, deviceId, clientNonce, serverNonce));
    final h = Hmac(sha256, master);
    return SessionKeys(
      clientToServer: Uint8List.fromList(h.convert(utf8.encode('c2s')).bytes),
      serverToClient: Uint8List.fromList(h.convert(utf8.encode('s2c')).bytes),
      transfer: Uint8List.fromList(h.convert(utf8.encode('xfer')).bytes),
    );
  }
}

/// Per-session, per-direction keys. Separate directions prevent reflecting a
/// coordinator frame back at it; [transfer] signs LAN download requests.
class SessionKeys {
  final Uint8List clientToServer;
  final Uint8List serverToClient;
  final Uint8List transfer;
  const SessionKeys({
    required this.clientToServer,
    required this.serverToClient,
    required this.transfer,
  });
}

/// Truncated (128-bit) HMAC-SHA256 tag, base64url.
String macTag(List<int> key, List<int> data) =>
    b64(Hmac(sha256, key).convert(data).bytes.sublist(0, 16));

/// Constant-time string comparison for MACs/proofs.
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var diff = x.length ^ y.length;
  final n = min(x.length, y.length);
  for (var i = 0; i < n; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

/// Signed authorisation for LAN track downloads:
/// `<sessionId>.<expiryCoordMs>.<tag>` with
/// `tag = HMAC(transferKey, "GET|<path>|<expiry>")`.
String signTransfer(String sessionId, List<int> transferKey, String path, int expiryMs, {String method = 'GET'}) =>
    '$sessionId.$expiryMs.${macTag(transferKey, utf8.encode('$method|$path|$expiryMs'))}';

/// Signed authorisation for uploading a track to the coordinator
/// (`PUT /uploads/<sha256>`); the MAC covers the method, so a download token
/// can never be replayed as an upload.
String signUpload(String sessionId, List<int> transferKey, String path, int expiryMs) =>
    signTransfer(sessionId, transferKey, path, expiryMs, method: 'PUT');

class TransferToken {
  final String sessionId;
  final int expiryMs;
  final String tag;
  TransferToken(this.sessionId, this.expiryMs, this.tag);

  static TransferToken? parse(String header) {
    final parts = header.split('.');
    if (parts.length != 3) return null;
    final exp = int.tryParse(parts[1]);
    if (exp == null || parts[0].isEmpty || parts[0].length > 64) return null;
    return TransferToken(parts[0], exp, parts[2]);
  }

  bool verify(List<int> transferKey, String path, {String method = 'GET'}) => constantTimeEquals(
      tag, macTag(transferKey, utf8.encode('$method|$path|$expiryMs')));
}
