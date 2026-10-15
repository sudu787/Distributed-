import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

void main() {
  test('round trip', () {
    final l = JoinLink(hosts: ['192.168.1.20', '10.0.0.5'], port: 47800, joinKey: 'abcd-efgh-jkmn', roomId: 'R00M42');
    final s = l.toString();
    expect(s, startsWith('syncsphere://app/join?'));
    final p = JoinLink.tryParse('  $s\n')!;
    expect(p.hosts, ['192.168.1.20', '10.0.0.5']);
    expect(p.port, 47800);
    expect(p.joinKey, 'ABCDEFGHJKMN');
    expect(p.roomId, 'R00M42');
  });

  test('survives the percent-decoding Flutter applies to deep-link routes', () {
    final l = JoinLink(hosts: ['192.168.1.20', '10.0.0.5'], port: 47800, joinKey: 'ABCD', roomId: 'R00M42');
    final u = l.toUri();
    final route = Uri.decodeComponent(Uri(path: u.path, queryParameters: u.queryParameters).toString());
    final p = JoinLink.tryParse(route)!;
    expect(p.hosts, ['192.168.1.20', '10.0.0.5']);
    expect(p.roomId, 'R00M42');
  });

  test('accepts the deep-link route form and the short host form', () {
    expect(JoinLink.tryParse('/join?h=192.168.0.2&p=1234&k=ABCD')!.port, 1234);
    expect(JoinLink.tryParse('syncsphere://join?h=192.168.0.2&p=1234&k=ABCD')!.hosts, ['192.168.0.2']);
  });

  test('rejects malformed links', () {
    for (final bad in [
      '',
      'https://example.com/join?h=1.2.3.4&p=1&k=A',
      'syncsphere://app/other?h=1.2.3.4&p=1&k=A',
      'syncsphere://app/join?p=47800&k=ABCD',
      'syncsphere://app/join?h=1.2.3.4&k=ABCD',
      'syncsphere://app/join?h=1.2.3.4&p=0&k=ABCD',
      'syncsphere://app/join?h=1.2.3.4&p=70000&k=ABCD',
      'syncsphere://app/join?h=1.2.3.4&p=1&k=',
      'syncsphere://app/join?h=1.2.3.4&p=1&k=%F0%9F%98%80',
      'syncsphere://app/join?h=bad host&p=1&k=ABCD',
      'syncsphere://app/join?h=1.2.3.4&p=1&k=${'A' * 65}',
      'syncsphere://app/join?h=1.2.3.4&p=1&k=ABCD&r=bad%20room',
      'not a link at all',
    ]) {
      expect(JoinLink.tryParse(bad), isNull, reason: bad);
    }
  });

  test('ranks private LAN addresses first and drops loopback/link-local', () {
    expect(rankLanAddresses(['100.64.0.1', '172.20.1.1', '127.0.0.1', '10.1.1.1', '169.254.3.3', '192.168.4.4']),
        ['192.168.4.4', '10.1.1.1', '172.20.1.1', '100.64.0.1']);
  });
}
