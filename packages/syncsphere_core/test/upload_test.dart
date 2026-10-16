/// Guest song uploads over real loopback sockets: `PUT /uploads/<sha256>`.
@Timeout(Duration(minutes: 1))
library;

import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  late TrackFileServer files;
  final log = EventLog(clock: SystemMonotonicClock.instance);
  final roomKey = RoomKey.derive(roomId: 'r', joinKey: 'K', iterations: 1);
  final keys = roomKey.sessionKeys('dev-1', 'cn', 'sn');
  final accepted = <String, File>{};
  var controllers = <String>{'sess-ctl'};

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('syncsphere_upload');
    accepted.clear();
    controllers = {'sess-ctl'};
    files = TrackFileServer(
      fileForTrack: (id) => accepted[id],
      keysForSession: (s) => s.startsWith('sess-') ? keys : null,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
      log: log,
      config: const TransferConfig(maxFileBytes: 200000),
      canUpload: controllers.contains,
      uploadDir: Directory('${tmp.path}/incoming'),
      acceptUpload: (id, f) async => accepted[id] = await f.copy('${tmp.path}/$id'),
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(files.handle);
  });
  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  List<int> bytes(int n, int seed) {
    final r = Random(seed);
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  Future<(int, String)> put(String id, List<int> body,
      {String session = 'sess-ctl', String method = 'PUT', List<int>? key}) async {
    final path = '/uploads/$id';
    final client = HttpClient();
    try {
      final req = await client.openUrl('PUT', Uri.parse('http://127.0.0.1:${server.port}$path'));
      final exp = DateTime.now().millisecondsSinceEpoch + 60000;
      req.headers.set('x-syncsphere-auth', signTransfer(session, key ?? keys.transfer, path, exp, method: method));
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close();
      return (res.statusCode, await res.transform(const SystemEncoding().decoder).join());
    } on SocketException {
      return (-1, 'connection closed');
    } on HttpException {
      return (-1, 'connection closed');
    } finally {
      client.close(force: true);
    }
  }

  test('accepts a verified upload from a controller and serves it', () async {
    final data = bytes(50000, 1);
    final id = sha256.convert(data).toString();
    final (status, _) = await put(id, data);
    expect(status, HttpStatus.created);
    expect(accepted[id]!.readAsBytesSync(), data);
    expect(files.bytesUploaded, data.length);
    // Nothing is left behind in the incoming folder.
    expect(Directory('${tmp.path}/incoming').listSync(), isEmpty);
  });

  test('refuses listeners, forged tokens, download tokens, wrong content and oversized files', () async {
    final data = bytes(1000, 2);
    final id = sha256.convert(data).toString();
    expect((await put(id, data, session: 'sess-listener')).$1, HttpStatus.forbidden);
    expect((await put(id, data, key: List.filled(32, 7))).$1, HttpStatus.unauthorized);
    // A GET (download) token must not authorise an upload.
    expect((await put(id, data, method: 'GET')).$1, HttpStatus.unauthorized);
    final other = bytes(1000, 3);
    expect((await put(id, other)).$1, HttpStatus.unprocessableEntity);
    final big = bytes(250000, 4);
    final r = await put(sha256.convert(big).toString(), big);
    expect(r.$1, anyOf(HttpStatus.requestEntityTooLarge, -1));
    expect(accepted, isEmpty);
  });

  test('uploads disabled without callbacks', () async {
    final plain = TrackFileServer(
      fileForTrack: (_) => null,
      keysForSession: (_) => keys,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
      log: log,
    );
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(plain.handle);
    final client = HttpClient();
    final req = await client.openUrl('PUT', Uri.parse('http://127.0.0.1:${s.port}/uploads/${'a' * 64}'));
    req.contentLength = 0;
    final res = await req.close();
    expect(res.statusCode, HttpStatus.methodNotAllowed);
    client.close(force: true);
    await s.close(force: true);
  });
}
