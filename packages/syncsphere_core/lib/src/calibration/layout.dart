/// Surround calibration with every phone's microphone: where the phones
/// are, which role each should play and how loud.
///
/// 1. **Distances** by two-way acoustic ranging (BeepBeep, Peng et al.,
///    SenSys 2007). Phones x and y both record both clicks; with A_x(y) the
///    arrival of y's click in x's own recording,
///    `d_xy = c/2 · [(A_x(y) − A_x(x)) − (A_y(y) − A_y(x))] + (d_xx + d_yy)/2`.
///    Every term is a difference inside one recording, so clock offsets,
///    scheduling error and output latency cancel; only onset detection
///    matters.
/// 2. **Positions** by classical multidimensional scaling of the distance
///    matrix (as in microphone-array self-calibration, Birchfield &
///    Subramanya). The result is only known up to rotation and mirroring.
/// 3. **Orientation** from two taps: the phone(s) in front and a phone on
///    the left of the listener.
/// 4. **Roles** from each phone's angle; **levels** from the click loudness
///    at the listener.
library;

import 'dart:math';

import '../model/calibration_plan.dart';
import '../model/room_state.dart';

const kSpeedOfSound = 343.0;

/// Distance from a phone's loudspeaker to its own microphone (m).
const kSelfDistanceM = 0.08;

/// Pairwise distances (m) between recording phones from their click
/// arrivals: `arrivals[recorder][clicker][slot]` = arrival − scheduled time
/// (µs) in that recorder's recording. Median over rounds; pairs without a
/// complete round are missing.
Map<String, Map<String, double>> pairwiseDistances({
  required CalibrationPlan plan,
  required Map<String, Map<String, Map<int, int>>> arrivals,
  double speedOfSound = kSpeedOfSound,
  double selfDistanceM = kSelfDistanceM,
}) {
  final ids = [
    for (final id in plan.order)
      if (arrivals.containsKey(id)) id
  ];
  final n = plan.order.length;
  final out = <String, Map<String, double>>{};
  for (var a = 0; a < ids.length; a++) {
    for (var b = a + 1; b < ids.length; b++) {
      final x = ids[a], y = ids[b];
      final kx = plan.order.indexOf(x), ky = plan.order.indexOf(y);
      final ax = arrivals[x]!, ay = arrivals[y]!;
      final samples = <double>[];
      for (var r = 0; r < plan.rounds; r++) {
        final sx = r * n + kx, sy = r * n + ky;
        final xy = ax[y]?[sy], xx = ax[x]?[sx], yy = ay[y]?[sy], yx = ay[x]?[sx];
        if (xy == null || xx == null || yy == null || yx == null) continue;
        final deltaUs = (xy - xx) - (yy - yx);
        samples.add(speedOfSound / 2 * deltaUs / 1e6 + selfDistanceM);
      }
      if (samples.isEmpty) continue;
      samples.sort();
      final d = max(0.0, samples[samples.length ~/ 2]);
      (out[x] ??= {})[y] = d;
      (out[y] ??= {})[x] = d;
    }
  }
  return out;
}

/// Largest set of phones with a distance for every pair (greedy: drop the
/// phone with the most missing pairs until complete).
List<String> completeSubset(List<String> ids, Map<String, Map<String, double>> d) {
  final keep = [...ids];
  while (keep.length > 1) {
    String? worst;
    var worstMissing = 0;
    for (final x in keep) {
      final missing = keep.where((y) => y != x && d[x]?[y] == null).length;
      if (missing > worstMissing) {
        worstMissing = missing;
        worst = x;
      }
    }
    if (worst == null) break;
    keep.remove(worst);
  }
  return keep;
}

/// Classical MDS: 2-D coordinates whose distances best match [d]
/// (all pairs of [ids] must be present).
Map<String, Point<double>> classicalMds(List<String> ids, Map<String, Map<String, double>> d) {
  final n = ids.length;
  if (n == 0) return {};
  if (n == 1) return {ids.first: const Point(0, 0)};
  // B = −½ J D² J (double centering of squared distances).
  final d2 = List.generate(n, (i) => List.generate(n, (j) => i == j ? 0.0 : pow(d[ids[i]]![ids[j]]!, 2).toDouble()));
  final rowMean = [for (final r in d2) r.reduce((a, b) => a + b) / n];
  final total = rowMean.reduce((a, b) => a + b) / n;
  final b = List.generate(n, (i) => List.generate(n, (j) => -0.5 * (d2[i][j] - rowMean[i] - rowMean[j] + total)));
  final (values, vectors) = _jacobiEigen(b);
  final order = List.generate(n, (i) => i)..sort((p, q) => values[q].compareTo(values[p]));
  final l1 = max(0.0, values[order[0]]), l2 = n > 2 ? max(0.0, values[order[1]]) : 0.0;
  return {
    for (var i = 0; i < n; i++)
      ids[i]: Point(vectors[i][order[0]] * sqrt(l1), n > 2 ? vectors[i][order[1]] * sqrt(l2) : 0.0),
  };
}

/// Root-mean-square difference between the layout's distances and [d] (m).
double layoutResidual(Map<String, Point<double>> pos, Map<String, Map<String, double>> d) {
  final ids = pos.keys.toList();
  var sum = 0.0;
  var count = 0;
  for (var i = 0; i < ids.length; i++) {
    for (var j = i + 1; j < ids.length; j++) {
      final m = d[ids[i]]?[ids[j]];
      if (m == null) continue;
      sum += pow(pos[ids[i]]!.distanceTo(pos[ids[j]]!) - m, 2);
      count++;
    }
  }
  return count == 0 ? 0 : sqrt(sum / count);
}

/// Eigen-decomposition of a symmetric matrix (cyclic Jacobi). Returns the
/// eigenvalues and the eigenvectors as columns.
(List<double>, List<List<double>>) _jacobiEigen(List<List<double>> m) {
  final n = m.length;
  final a = [
    for (final r in m) [...r]
  ];
  final v = List.generate(n, (i) => List.generate(n, (j) => i == j ? 1.0 : 0.0));
  for (var sweep = 0; sweep < 100; sweep++) {
    var off = 0.0;
    for (var p = 0; p < n; p++) {
      for (var q = p + 1; q < n; q++) {
        off += a[p][q] * a[p][q];
      }
    }
    if (off < 1e-18) break;
    for (var p = 0; p < n; p++) {
      for (var q = p + 1; q < n; q++) {
        if (a[p][q].abs() < 1e-15) continue;
        final theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
        final t = (theta >= 0 ? 1 : -1) / (theta.abs() + sqrt(theta * theta + 1));
        final c = 1 / sqrt(t * t + 1), s = t * c;
        for (var k = 0; k < n; k++) {
          final akp = a[k][p], akq = a[k][q];
          a[k][p] = c * akp - s * akq;
          a[k][q] = s * akp + c * akq;
        }
        for (var k = 0; k < n; k++) {
          final apk = a[p][k], aqk = a[q][k];
          a[p][k] = c * apk - s * aqk;
          a[q][k] = s * apk + c * aqk;
        }
        for (var k = 0; k < n; k++) {
          final vkp = v[k][p], vkq = v[k][q];
          v[k][p] = c * vkp - s * vkq;
          v[k][q] = s * vkp + c * vkq;
        }
      }
    }
  }
  return ([for (var i = 0; i < n; i++) a[i][i]], v);
}

/// Where a phone is, seen from the listener: angle (degrees; 0 = straight
/// ahead, negative = left) and distance (m).
typedef Placement = ({double azimuthDeg, double distanceM});

/// Orients an MDS layout: [listener] at the origin, straight ahead midway
/// between the [front] phones (one center phone, or a front-left and a
/// front-right one), and [left] on the left (fixes the mirror ambiguity).
Map<String, Placement> orientLayout(
  Map<String, Point<double>> pos, {
  required String listener,
  required List<String> front,
  required String left,
}) {
  final o = pos[listener]!;
  final rel = {for (final e in pos.entries) e.key: e.value - o};
  var fx = 0.0, fy = 0.0;
  for (final id in front) {
    final v = rel[id]!;
    final m = v.magnitude;
    if (m > 0) {
      fx += v.x / m;
      fy += v.y / m;
    }
  }
  final theta = atan2(fx, fy); // forward direction, measured from +y
  Point<double> rot(Point<double> p) => Point(p.x * cos(theta) - p.y * sin(theta), p.x * sin(theta) + p.y * cos(theta));
  var turned = {for (final e in rel.entries) e.key: rot(e.value)};
  if ((turned[left]?.x ?? -1) > 0) turned = {for (final e in turned.entries) e.key: Point(-e.value.x, e.value.y)};
  return {
    for (final e in turned.entries)
      if (e.key != listener) e.key: (azimuthDeg: atan2(e.value.x, e.value.y) * 180 / pi, distanceM: e.value.magnitude),
  };
}

/// Suggested role for every phone from its angle around the listener:
/// 2 phones → left/right; otherwise center (nearest straight ahead, within
/// ±20°), front left/right (within ±75°) and surround left/right (further
/// round). Phones without a placement are not included.
Map<String, ChannelRole> assignSurroundRoles(Map<String, Placement> placements) {
  final ids = placements.keys.toList()..sort((a, b) => placements[a]!.azimuthDeg.compareTo(placements[b]!.azimuthDeg));
  if (ids.isEmpty) return {};
  if (ids.length == 1) return {ids.first: ChannelRole.stereo};
  if (ids.length == 2) return {ids.first: ChannelRole.left, ids.last: ChannelRole.right};
  final roles = <String, ChannelRole>{};
  String? center;
  var best = 21.0;
  for (final id in ids) {
    final a = placements[id]!.azimuthDeg.abs();
    if (a < best) {
      best = a;
      center = id;
    }
  }
  if (center != null) roles[center] = ChannelRole.center;
  for (final id in ids) {
    if (id == center) continue;
    final a = placements[id]!.azimuthDeg;
    roles[id] = a.abs() <= 75
        ? (a < 0 ? ChannelRole.left : ChannelRole.right)
        : (a < 0 ? ChannelRole.surroundLeft : ChannelRole.surroundRight);
  }
  return roles;
}

/// Volume trims (dB, ≤ 0) so every phone arrives equally loud at the
/// listener: everyone is brought down to the quietest front phone, and
/// rear phones a further 3 dB. [levelsDb] are click levels measured at the
/// listener. Phones without a role (such as the listener's own phone, which
/// is right next to the microphone) are left out.
Map<String, double> levelTrimsDb(Map<String, double> levelsDb, Map<String, ChannelRole> roles) {
  final levels = {
    for (final e in levelsDb.entries)
      if (roles.containsKey(e.key)) e.key: e.value
  };
  final fronts = [
    for (final e in levels.entries)
      if (!roles[e.key]!.isRear) e.value
  ];
  if (fronts.isEmpty) return {};
  final target = fronts.reduce(min);
  return {
    for (final e in levels.entries) e.key: (target - e.value - (roles[e.key]!.isRear ? 3.0 : 0.0)).clamp(-20.0, 0.0),
  };
}
