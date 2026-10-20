/// LAN track delivery served by the coordinator: `GET /tracks/<sha256>`.
///
/// * Authorisation: header `X-SyncSphere-Auth: <session>.<expiryMs>.<tag>`
///   where `tag = HMAC(transferKey, "GET|<path>|<expiry>")`. Only members of
///   the room with a live session can download, tokens expire in the
///   coordinator's clock domain, and a token is valid for one path only.
/// * Only tracks in the room's playlist that the host serves are reachable;
///   the URL never contains a filesystem path (no traversal surface).
/// * Supports single `Range: bytes=a-b` requests (RFC 9110) so interrupted
///   downloads resume instead of restarting.
/// * Resource limits: max concurrent transfers per session and in total.
///
/// Uploads (`PUT /uploads/<sha256>`) let a guest with control rights give the
/// host a song from their phone. The token MAC covers the method
/// (`PUT|<path>|<expiry>`), only members allowed to control may upload, one
/// upload per session at a time, the size is capped, and the body is stored
/// only if its SHA-256 equals the id in the URL (so the id stays a content
/// address and nobody can substitute a different file for a track).
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../config/sync_config.dart';
import '../observability/event_log.dart';
import '../protocol/auth.dart';
import '../model/room_state.dart';

class TrackFileServer {
  final TransferConfig config;
  final EventLog log;

  /// Maps a track id to the local file the host serves (null if not served).
  final File? Function(String trackId) fileForTrack;

  /// Looks up transfer keys of a live session (null if unknown/offline).
  final SessionKeys? Function(String sessionId) keysForSession;

  /// Coordinator clock in ms, for token expiry.
  final int Function() nowMs;

  /// Uploads: whether the session may add songs (member allowed to control).
  /// Null disables uploads.
  final bool Function(String sessionId)? canUpload;

  /// Takes ownership of a verified upload (file named after its hash).
  final Future<void> Function(String trackId, File file)? acceptUpload;

  /// Where incoming uploads are written while they are verified.
  final Directory? uploadDir;

  final Set<String> _uploading = {};
  int bytesUploaded = 0;

  final Map<String, int> _activePerSession = {};
  int _activeTotal = 0;
  int bytesServed = 0;
  int requestsServed = 0;

  TrackFileServer({
    required this.fileForTrack,
    required this.keysForSession,
    required this.nowMs,
    required this.log,
    this.config = const TransferConfig(),
    this.canUpload,
    this.acceptUpload,
    this.uploadDir,
  });

  /// HTTP handler, mount it on the coordinator's `HttpServer`.
  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    if (req.method == 'PUT' && path.startsWith('/uploads/')) return _handleUpload(req);
    if (req.method != 'GET' && req.method != 'HEAD') {
      return _fail(res, HttpStatus.methodNotAllowed, 'method not allowed');
    }
    if (!path.startsWith('/tracks/')) {
      return _fail(res, HttpStatus.notFound, 'not found');
    }
    final id = path.substring('/tracks/'.length);
    if (!TrackInfo.isValidTrackId(id)) {
      return _fail(res, HttpStatus.badRequest, 'invalid track id');
    }
    final header = req.headers.value('x-syncsphere-auth');
    final token = header == null ? null : TransferToken.parse(header);
    final keys = token == null ? null : keysForSession(token.sessionId);
    if (token == null || keys == null || !token.verify(keys.transfer, path)) {
      log.warn('transfer.auth', 'unauthorised download attempt for ${id.substring(0, 8)} from ${req.connectionInfo?.remoteAddress.address}');
      return _fail(res, HttpStatus.unauthorized, 'unauthorised');
    }
    if (token.expiryMs < nowMs()) {
      return _fail(res, HttpStatus.unauthorized, 'token expired');
    }
    final file = fileForTrack(id);
    if (file == null || !await file.exists()) {
      return _fail(res, HttpStatus.notFound, 'track not served');
    }
    final length = await file.length();
    if (length > config.maxFileBytes) {
      return _fail(res, HttpStatus.requestEntityTooLarge, 'file exceeds transfer limit');
    }
    final perSession = _activePerSession[token.sessionId] ?? 0;
    if (perSession >= config.maxConcurrentPerSession || _activeTotal >= config.maxConcurrentTotal) {
      res.headers.set(HttpHeaders.retryAfterHeader, '2');
      return _fail(res, HttpStatus.tooManyRequests, 'too many concurrent transfers');
    }

    var start = 0, end = length - 1;
    var partial = false;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final r = parseByteRange(range, length);
      if (r == null) {
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        return _fail(res, HttpStatus.requestedRangeNotSatisfiable, 'bad range');
      }
      (start, end) = r;
      partial = true;
    }

    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    res.headers.set(HttpHeaders.etagHeader, '"$id"');
    res.headers.contentType = ContentType('application', 'octet-stream');
    res.contentLength = length == 0 ? 0 : end - start + 1;
    if (partial) {
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
    }
    if (req.method == 'HEAD' || length == 0) {
      await res.close();
      return;
    }

    _activePerSession[token.sessionId] = perSession + 1;
    _activeTotal++;
    requestsServed++;
    try {
      await res.addStream(file.openRead(start, end + 1).map((chunk) {
        bytesServed += chunk.length;
        return chunk;
      }));
      await res.close();
    } on SocketException catch (e) {
      log.info('transfer.aborted', 'client aborted download of ${id.substring(0, 8)}: ${e.message}');
    } on HttpException catch (e) {
      log.info('transfer.aborted', 'download of ${id.substring(0, 8)} interrupted: ${e.message}');
    } finally {
      _activeTotal--;
      final n = (_activePerSession[token.sessionId] ?? 1) - 1;
      if (n <= 0) {
        _activePerSession.remove(token.sessionId);
      } else {
        _activePerSession[token.sessionId] = n;
      }
    }
  }

  Future<void> _handleUpload(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    final id = path.substring('/uploads/'.length);
    final accept = acceptUpload, dir = uploadDir, allowed = canUpload;
    if (accept == null || dir == null || allowed == null) {
      return _drainAndFail(req, HttpStatus.methodNotAllowed, 'uploads disabled');
    }
    if (!TrackInfo.isValidTrackId(id)) return _drainAndFail(req, HttpStatus.badRequest, 'invalid track id');
    final header = req.headers.value('x-syncsphere-auth');
    final token = header == null ? null : TransferToken.parse(header);
    final keys = token == null ? null : keysForSession(token.sessionId);
    if (token == null || keys == null || !token.verify(keys.transfer, path, method: 'PUT')) {
      log.warn('upload.auth', 'unauthorised upload attempt from ${req.connectionInfo?.remoteAddress.address}');
      return _drainAndFail(req, HttpStatus.unauthorized, 'unauthorised');
    }
    if (token.expiryMs < nowMs()) return _drainAndFail(req, HttpStatus.unauthorized, 'token expired');
    if (!allowed(token.sessionId)) return _drainAndFail(req, HttpStatus.forbidden, 'only members who control the music can add songs');
    final declared = req.contentLength;
    if (declared > config.maxFileBytes) return _drainAndFail(req, HttpStatus.requestEntityTooLarge, 'file exceeds transfer limit');
    if (_uploading.contains(token.sessionId)) {
      res.headers.set(HttpHeaders.retryAfterHeader, '2');
      return _drainAndFail(req, HttpStatus.tooManyRequests, 'upload already in progress');
    }
    _uploading.add(token.sessionId);
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/.upload-${token.sessionId.hashCode.toRadixString(16)}-$id');
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    var received = 0;
    var tooLarge = false;
    IOSink? out;
    try {
      out = tmp.openWrite();
      await for (final chunk in req) {
        received += chunk.length;
        if (received > config.maxFileBytes) {
          tooLarge = true;
          break;
        }
        hasher.add(chunk);
        out.add(chunk);
      }
      await out.close();
      out = null;
      hasher.close();
      // Remove the temporary file before answering, so a client that saw the
      // answer never finds leftovers.
      Future<void> discard() async {
        if (await tmp.exists()) await tmp.delete();
      }

      if (tooLarge || received == 0 || digest.value.toString() != id) {
        await discard();
        if (tooLarge) return await _fail(res, HttpStatus.requestEntityTooLarge, 'file exceeds transfer limit');
        if (received == 0) return await _fail(res, HttpStatus.badRequest, 'empty upload');
        log.warn('upload.hash', 'upload for ${id.substring(0, 8)} does not match its id; discarded');
        return await _fail(res, HttpStatus.unprocessableEntity, 'content does not match track id');
      }
      await accept(id, tmp);
      await discard();
      bytesUploaded += received;
      log.info('upload.done', 'received ${id.substring(0, 8)} (${received ~/ 1024} KiB)');
      res.statusCode = HttpStatus.created;
      await res.close();
    } on SocketException catch (e) {
      log.info('upload.aborted', 'upload of ${id.substring(0, 8)} aborted: ${e.message}');
    } on HttpException catch (e) {
      log.info('upload.aborted', 'upload of ${id.substring(0, 8)} interrupted: ${e.message}');
    } finally {
      _uploading.remove(token.sessionId);
      try {
        await out?.close();
      } catch (_) {}
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }
  }

  /// Rejects a request carrying a body. The body is discarded rather than
  /// read, and the connection is closed so a large rejected upload does not
  /// keep streaming.
  Future<void> _drainAndFail(HttpRequest req, int status, String msg) async {
    req.response.persistentConnection = false;
    await _fail(req.response, status, msg);
  }

  Future<void> _fail(HttpResponse res, int status, String msg) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.text;
    res.write(msg);
    await res.close();
  }
}

/// Parses a single-range `bytes=` header. Returns inclusive (start, end) or
/// null if unsatisfiable/unsupported (multi-range is not supported).
(int, int)? parseByteRange(String header, int length) {
  final h = header.trim();
  if (!h.startsWith('bytes=') || h.contains(',')) return null;
  final spec = h.substring(6);
  final dash = spec.indexOf('-');
  if (dash < 0) return null;
  final a = spec.substring(0, dash).trim(), b = spec.substring(dash + 1).trim();
  if (length <= 0) return null;
  if (a.isEmpty) {
    final suffix = int.tryParse(b);
    if (suffix == null || suffix <= 0) return null;
    final s = suffix >= length ? 0 : length - suffix;
    return (s, length - 1);
  }
  final start = int.tryParse(a);
  if (start == null || start < 0 || start >= length) return null;
  var end = b.isEmpty ? length - 1 : int.tryParse(b);
  if (end == null || end < start) return null;
  if (end >= length) end = length - 1;
  return (start, end);
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
