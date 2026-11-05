/// Result of a *Sync check*: how far apart the phones actually sound at the
/// listener's microphone, measured with the calibration click machinery but
/// without changing anything.
///
/// Offsets are relative to the median phone and positive when a phone is
/// heard *late*. "Start" is the first click of each phone (within the first
/// seconds after a synchronized start, which is where an echo shows up);
/// "settled" is the median of the second half of the clicks.
library;

import '../protocol/reader.dart';
import 'sync_engine.dart';

/// How many results the room keeps (enough to compare all engines twice).
const kMaxSyncChecks = 6;

class SyncCheckDevice {
  final String deviceId;
  final String name;

  /// Offset of the first click (µs), or null when it was not heard.
  final int? startUs;

  /// Median offset of the settled clicks (µs), or null when not heard.
  final int? settledUs;

  /// Max − min of the settled clicks (µs): how steady the phone is.
  final int jitterUs;

  const SyncCheckDevice({
    required this.deviceId,
    required this.name,
    this.startUs,
    this.settledUs,
    this.jitterUs = 0,
  });

  bool get heard => startUs != null || settledUs != null;

  Map<String, Object?> toJson() => {
        'id': deviceId,
        'name': name,
        if (startUs != null) 's': startUs,
        if (settledUs != null) 'm': settledUs,
        'j': jitterUs,
      };

  factory SyncCheckDevice.fromJson(Map<String, Object?> j) {
    final r = Reader(j, 'syncCheckDevice');
    return SyncCheckDevice(
      deviceId: r.string('id', maxLength: 64),
      name: r.string('name', maxLength: 64),
      startUs: r.optInteger('s', min: -10000000, max: 10000000),
      settledUs: r.optInteger('m', min: -10000000, max: 10000000),
      jitterUs: r.integer('j', min: 0, max: 10000000),
    );
  }
}

class SyncCheckResult {
  final int id;
  final SyncEngineMode engine;

  /// Device whose microphone recorded the clicks.
  final String listener;
  final List<SyncCheckDevice> devices;

  /// Why the check produced no numbers (e.g. microphone failure), else null.
  final String? error;

  const SyncCheckResult({
    required this.id,
    required this.engine,
    required this.listener,
    this.devices = const [],
    this.error,
  });

  static int? _spread(Iterable<int?> values) {
    final v = values.whereType<int>().toList();
    if (v.length < 2) return null;
    v.sort();
    return v.last - v.first;
  }

  /// Largest gap between two phones at the start (µs).
  int? get startSpreadUs => _spread(devices.map((d) => d.startUs));

  /// Largest gap between two phones once settled (µs).
  int? get settledSpreadUs => _spread(devices.map((d) => d.settledUs));

  bool get ok => error == null && devices.where((d) => d.heard).length >= 2;

  Map<String, Object?> toJson() => {
        'id': id,
        'eng': engine.name,
        'lis': listener,
        'devs': [for (final d in devices) d.toJson()],
        if (error != null) 'err': error,
      };

  factory SyncCheckResult.fromJson(Map<String, Object?> j) {
    final r = Reader(j, 'syncCheck');
    return SyncCheckResult(
      id: r.integer('id', min: 0),
      engine: SyncEngineMode.parse(r.optString('eng', maxLength: 40)),
      listener: r.string('lis', maxLength: 64),
      devices: [for (final m in r.mapList('devs', maxLength: 64)) SyncCheckDevice.fromJson(m)],
      error: r.optString('err', maxLength: 200),
    );
  }
}
