import 'dart:convert';
import 'dart:math';

import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

void main() {
  // Listener at the origin facing +y; ITU-ish 5.1 layout, 2–2.5 m away.
  final truth = <String, Point<double>>{
    'seat': const Point(0, 0),
    'c': const Point(0, 2.4),
    'l': Point(-2.2 * sin(30 * pi / 180), 2.2 * cos(30 * pi / 180)),
    'r': Point(2.3 * sin(30 * pi / 180), 2.3 * cos(30 * pi / 180)),
    'sl': Point(-2.0 * sin(110 * pi / 180), 2.0 * cos(110 * pi / 180)),
    'sr': Point(2.1 * sin(110 * pi / 180), 2.1 * cos(110 * pi / 180)),
  };
  final ids = truth.keys.toList();
  final plan = CalibrationPlan(id: 1, listener: 'seat', order: ids, rounds: 3);

  double trueDist(String a, String b) => a == b ? kSelfDistanceM : truth[a]!.distanceTo(truth[b]!);

  /// Arrivals as each phone's recorder would measure them: emission time
  /// (with per-click scheduling error), propagation, plus the recorder's
  /// own unknown clock offset.
  Map<String, Map<String, Map<int, int>>> synthArrivals({double jitterUs = 0, int seed = 1}) {
    final rnd = Random(seed);
    final emission = {for (var s = 0; s < plan.slotCount; s++) s: rnd.nextInt(20000) - 10000};
    final offset = {for (final x in ids) x: rnd.nextInt(200000) - 100000};
    return {
      for (final x in ids)
        x: {
          for (final y in ids)
            y: {
              for (final s in plan.slotsOf(plan.order.indexOf(y)))
                s: (emission[s]! +
                        trueDist(x, y) / kSpeedOfSound * 1e6 +
                        offset[x]! +
                        (rnd.nextDouble() * 2 - 1) * jitterUs)
                    .round(),
            },
        },
    };
  }

  test('two-way ranging cancels clock offsets and scheduling error', () {
    final d = pairwiseDistances(plan: plan, arrivals: synthArrivals());
    for (final a in ids) {
      for (final b in ids) {
        if (a == b) continue;
        expect(d[a]![b]!, closeTo(trueDist(a, b), 0.002), reason: '$a–$b');
      }
    }
    // With ±100 µs onset jitter (≈ ±3 cm per term) the median over 3 rounds stays within ~10 cm.
    final noisy = pairwiseDistances(plan: plan, arrivals: synthArrivals(jitterUs: 100, seed: 4));
    expect(noisy['l']!['r']!, closeTo(trueDist('l', 'r'), 0.10));
  });

  test('MDS recovers the layout up to rotation and mirroring; orientation from two taps', () {
    final d = pairwiseDistances(plan: plan, arrivals: synthArrivals());
    final pos = classicalMds(ids, d);
    expect(layoutResidual(pos, d), lessThan(0.01));
    final placed = orientLayout(pos, listener: 'seat', front: ['c'], left: 'l');
    expect(placed['c']!.azimuthDeg, closeTo(0, 1));
    expect(placed['l']!.azimuthDeg, closeTo(-30, 2));
    expect(placed['r']!.azimuthDeg, closeTo(30, 2));
    expect(placed['sl']!.azimuthDeg, closeTo(-110, 2));
    expect(placed['sr']!.azimuthDeg, closeTo(110, 2));
    expect(placed['sr']!.distanceM, closeTo(2.1, 0.02));
    expect(placed.containsKey('seat'), isFalse);
    // No center phone: forward is midway between the front-left and
    // front-right phones.
    final byPair = orientLayout(pos, listener: 'seat', front: ['l', 'r'], left: 'sl');
    expect(byPair['c']!.azimuthDeg, closeTo(0, 1));
    expect(byPair['l']!.azimuthDeg, closeTo(-30, 2));
    expect(byPair['sr']!.azimuthDeg, closeTo(110, 2));
  });

  test('roles from angles', () {
    Placement at(double a) => (azimuthDeg: a, distanceM: 2);
    expect(assignSurroundRoles({'c': at(2), 'l': at(-32), 'r': at(28), 'sl': at(-105), 'sr': at(118)}), {
      'c': ChannelRole.center,
      'l': ChannelRole.left,
      'r': ChannelRole.right,
      'sl': ChannelRole.surroundLeft,
      'sr': ChannelRole.surroundRight,
    });
    expect(assignSurroundRoles({'a': at(40), 'b': at(-35)}), {'b': ChannelRole.left, 'a': ChannelRole.right});
    expect(assignSurroundRoles({'a': at(-40), 'b': at(45), 'c': at(-120)}),
        {'a': ChannelRole.left, 'b': ChannelRole.right, 'c': ChannelRole.surroundLeft});
  });

  test('level trims bring everyone to the quietest front phone, rears 3 dB lower', () {
    final trims = levelTrimsDb(
      {'l': -20, 'r': -26, 'c': -23, 'sl': -18, 'seat': -3},
      {'l': ChannelRole.left, 'r': ChannelRole.right, 'c': ChannelRole.center, 'sl': ChannelRole.surroundLeft},
    );
    expect(trims, {'l': -6.0, 'r': 0.0, 'c': -3.0, 'sl': -11.0});
  });

  test('incomplete pairs: the largest complete subset is used', () {
    final d = {
      'a': {'b': 1.0, 'c': 1.0},
      'b': {'a': 1.0, 'c': 1.0},
      'c': {'a': 1.0, 'b': 1.0},
      'x': <String, double>{},
    };
    expect(completeSubset(['a', 'b', 'c', 'x'], d)..sort(), ['a', 'b', 'c']);
  });

  test('protocol: surround plan, levels and layout survive the wire', () {
    final p = CalibrationPlan.fromJson(
        CalibrationPlan(id: 4, listener: 'a', order: const ['a', 'b', 'c'], recorders: const ['a', 'b', 'c']).toJson());
    expect(p.recorders, ['a', 'b', 'c']);
    expect(p.isSurround, isTrue);
    expect(CalibrationPlan.fromJson(const CalibrationPlan(id: 1, listener: 'a', order: ['a']).toJson()).isSurround,
        isFalse);

    final c = FrameCodec(), s = FrameCodec();
    final keys = RoomKey.derive(roomId: 'r', joinKey: 'k', iterations: 1).sessionKeys('d', 'a', 'b');
    c.activate(sendKey: keys.clientToServer, recvKey: keys.serverToClient);
    s.activate(sendKey: keys.serverToClient, recvKey: keys.clientToServer);
    final m = s.decode(c.encode(const CalibrationResultMsg(calibrationId: 4, arrivals: {
      'b': {1: 100}
    }, levels: {
      'b': -21.5
    }))) as CalibrationResultMsg;
    expect(m.levels, {'b': -21.5});
    final ctl = s.decode(
            c.encode(const ControlMsg(requestId: 1, action: ControlAction.calibrate, baseVersion: 0, mode: 'surround')))
        as ControlMsg;
    expect(ctl.mode, 'surround');

    const layout = SpeakerLayout(
        id: 4, listener: 'a', positions: {'a': (0, 0), 'b': (1.25, 2.5)}, levelsDb: {'b': -20}, residualM: 0.02);
    final back = SpeakerLayout.fromJson(jsonDecode(jsonEncode(layout.toJson())) as Map<String, Object?>);
    expect(back.positions['b'], (1.25, 2.5));
    expect(back.levelsDb, {'b': -20.0});
    expect(back.residualM, 0.02);
    expect(
        () => SpeakerLayout.fromJson({
              'id': 1,
              'listener': 'a',
              'pos': {
                'b': [1, 'x']
              },
              'res': 0
            }),
        throwsA(isA<ProtocolException>()));
  });
}
