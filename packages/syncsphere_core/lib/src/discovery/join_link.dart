/// Join links: everything a guest needs to join a room in one URI, shown as
/// a QR code on the host and opened by scanning it, by tapping a shared
/// link, or by pasting it.
///
/// `syncsphere://app/join?h=192.168.1.20,10.0.0.5&p=47800&r=ROOMID&k=JOINKEY`
///
/// Every value uses URL-safe characters only, because Flutter's deep-link
/// handling percent-decodes the whole route before the app sees it (a room
/// name with `&` would break the query), so the room name is not included.
///
/// The link contains the join key, so it is exactly as sensitive as the key
/// itself: anyone who sees it can join. See docs/threat-model.md.
library;

import '../protocol/auth.dart';

class JoinLink {
  static const scheme = 'syncsphere';

  /// Candidate host addresses, best first (a host can be on several
  /// networks, e.g. Wi-Fi and its own hotspot).
  final List<String> hosts;
  final int port;
  final String joinKey;
  final String? roomId;

  JoinLink({
    required List<String> hosts,
    required this.port,
    required String joinKey,
    this.roomId,
  })  : hosts = List.unmodifiable(hosts),
        joinKey = normalizeJoinKey(joinKey);

  Uri toUri() => Uri(scheme: scheme, host: 'app', path: '/join', queryParameters: {
        'h': hosts.join(','),
        'p': '$port',
        'k': joinKey,
        if (roomId != null) 'r': roomId!,
      });

  @override
  String toString() => toUri().toString();

  /// Parses a join link (surrounding whitespace allowed). Also accepts the
  /// route form `/join?...` that Flutter's deep linking delivers. Returns
  /// null for anything malformed.
  static JoinLink? tryParse(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length > 1024) return null;
    final Uri u;
    try {
      u = Uri.parse(t);
    } on FormatException {
      return null;
    }
    final isUri = u.scheme == scheme && (u.host == 'app' || u.host == 'join');
    final isRoute = u.scheme.isEmpty && u.path == '/join';
    if (!isUri && !isRoute) return null;
    if (isUri && u.host == 'app' && u.path != '/join') return null;
    final q = u.queryParameters;
    final hosts = (q['h'] ?? '').split(',').map((h) => h.trim()).where(_validHost).toList();
    final port = int.tryParse(q['p'] ?? '');
    final key = normalizeJoinKey(q['k'] ?? '');
    if (hosts.isEmpty || hosts.length > 8 || port == null || port < 1 || port > 65535) return null;
    if (key.isEmpty || key.length > 64 || !RegExp(r'^[0-9A-Z]+$').hasMatch(key)) return null;
    final room = q['r'];
    if (room != null && !RegExp(r'^[0-9A-Za-z]{1,64}$').hasMatch(room)) return null;
    return JoinLink(hosts: hosts, port: port, joinKey: key, roomId: room);
  }

  static bool _validHost(String h) =>
      h.isNotEmpty && h.length <= 253 && RegExp(r'^[A-Za-z0-9.\-:\[\]]+$').hasMatch(h);
}

/// Orders a host's addresses for a join link: private LAN ranges first
/// (192.168/16, 10/8, 172.16/12), then everything else; loopback and
/// link-local addresses are dropped.
List<String> rankLanAddresses(Iterable<String> addresses) {
  int rank(String a) {
    if (a.startsWith('192.168.')) return 0;
    if (a.startsWith('10.')) return 1;
    final m = RegExp(r'^172\.(\d+)\.').firstMatch(a);
    if (m != null) {
      final second = int.parse(m.group(1)!);
      if (second >= 16 && second <= 31) return 2;
    }
    return 3;
  }

  final list = addresses.where((a) => !a.startsWith('127.') && !a.startsWith('169.254.') && a != '::1').toSet().toList();
  list.sort((a, b) => rank(a).compareTo(rank(b)));
  return list;
}
