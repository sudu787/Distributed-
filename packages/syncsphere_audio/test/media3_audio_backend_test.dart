import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncsphere_audio/syncsphere_audio.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

/// Fake native side whose nanoTime runs [offsetNs] ahead of the Dart clock.
class FakeNative implements NativeAudioApi {
  final ManualClock dart;
  final int offsetNs;
  final calls = <String, List<Object?>>{};
  final StreamController<Map<String, Object?>> ev = StreamController.broadcast();
  Map<String, Object?>? nextSample;

  FakeNative(this.dart, this.offsetNs);

  int get native => dart.nowMicros() * 1000 + offsetNs;

  @override
  Future<int> nowNanos() async {
    dart.advanceMicros(30); // channel hop
    final n = native;
    dart.advanceMicros(40);
    return n;
  }

  @override
  Future<Map<String, Object?>> init() async =>
      {'backend': 'media3-exoplayer', 'rateControl': true, 'outputLatencyHintUs': 45000};

  @override
  Future<void> prepare(int segment, String uri, int positionUs) async => calls['prepare'] = [segment, uri, positionUs];

  @override
  Future<void> startAt(int segment, int atNanos) async => calls['startAt'] = [segment, atNanos];

  @override
  Future<void> pauseAt(int segment, int atNanos, int? seekToUs) async => calls['pauseAt'] = [segment, atNanos, seekToUs];

  @override
  Future<void> setRate(double rate) async => calls['setRate'] = [rate];

  @override
  Future<void> setVolume(double volume) async => calls['setVolume'] = [volume];

  @override
  Future<void> stop() async => calls['stop'] = [];

  @override
  Future<Map<String, Object?>?> sample() async => nextSample;

  @override
  Future<Map<String, Object?>> acquireNetworkLocks() async => {};

  @override
  Future<void> releaseNetworkLocks() async {}

  @override
  Future<bool> keepScreenOn(bool on) async => true;

  @override
  Future<Map<String, Object?>> probe(String uri) async => {'durationMs': 1000};

  @override
  Stream<Map<String, Object?>> get events => ev.stream;
}

void main() {
  test('converts schedule times into the native clock domain', () async {
    final clock = ManualClock(5000000);
    final native = FakeNative(clock, 123456789000); // native is 123.456789 s ahead
    final b = Media3AudioBackend(api: native, clock: clock);
    await b.initialize();
    expect(b.capabilities.outputLatencyHintUs, 45000);
    final at = clock.nowMicros() + 300000;
    await b.startAt(segmentId: 3, atLocalUs: at);
    final sent = native.calls['startAt']![1] as int;
    final expected = at * 1000 + 123456789000;
    expect((sent - expected).abs(), lessThan(100000)); // < 100 µs
    await b.dispose();
  });

  test('maps native samples and events back to the Dart domain', () async {
    final clock = ManualClock(1000000);
    final native = FakeNative(clock, -50000000000);
    final b = Media3AudioBackend(api: native, clock: clock);
    await b.initialize();
    final nowNative = native.native;
    native.nextSample = {
      'segment': 1,
      'positionUs': 42000000,
      'atNanos': nowNative,
      'playing': true,
      'bufferedUs': 3000000,
      'rate': 1.0,
      'state': 'ready',
    };
    final s = (await b.samplePosition())!;
    expect((s.atLocalUs - clock.nowMicros()).abs(), lessThan(100));
    expect(s.positionUs, 42000000);

    final got = b.events.first;
    native.ev.add({'kind': 'playCalled', 'segment': 1, 'atNanos': nowNative});
    final e = await got;
    expect(e.kind, AudioEventKind.playCalled);
    expect((e.atLocalUs - clock.nowMicros()).abs(), lessThan(100));
    await b.dispose();
  });
}
