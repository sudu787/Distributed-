import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
  Future<void> setChannelRole(String role) async => calls['setChannelRole'] = [role];

  bool micGranted = true;
  Map<String, Object?>? recordResult;

  @override
  Future<bool> requestPermission(String name) async {
    calls['requestPermission'] = [name];
    return name != 'microphone' || micGranted;
  }

  @override
  Future<Map<String, Object?>> recordMic(int startAtNanos, int durationMs, int sampleRate) async {
    calls['recordMic'] = [startAtNanos, durationMs, sampleRate];
    return recordResult!;
  }

  @override
  Future<void> startService(String title, String text, bool playing) async =>
      calls['startService'] = [title, text, playing];

  @override
  Future<bool> updateService(String title, String text, bool playing) async {
    calls['updateService'] = [title, text, playing];
    return true;
  }

  @override
  Future<void> stopService() async => calls['stopService'] = [];

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

  test('channel role and notification commands', () async {
    final clock = ManualClock(1000000);
    final native = FakeNative(clock, 0);
    final b = Media3AudioBackend(api: native, clock: clock);
    await b.initialize();
    await b.setChannelRole(ChannelRole.left);
    expect(native.calls['setChannelRole'], ['left']);

    final cmd = b.notificationCommands.first;
    final audio = <AudioBackendEvent>[];
    final sub = b.events.listen(audio.add);
    native.ev.add({'kind': 'command', 'segment': -1, 'atNanos': native.native, 'message': 'pause'});
    expect(await cmd, 'pause');
    await Future<void>.delayed(Duration.zero);
    expect(audio, isEmpty, reason: 'commands are not audio events');
    await sub.cancel();
    await b.dispose();
  });

  test('calibration recorder converts times and decodes the WAV', () async {
    final clock = ManualClock(2000000);
    final native = FakeNative(clock, 7000000000); // native 7 s ahead
    final b = Media3AudioBackend(api: native, clock: clock);
    await b.initialize();
    final dir = await Directory.systemTemp.createTemp('ss-mic');
    final f = File('${dir.path}/rec.wav');
    final pcm = Int16List.fromList(List.generate(1600, (i) => i.isEven ? 1000 : -1000));
    await f.writeAsBytes(encodeWav(pcm, sampleRate: 16000));
    final startLocal = clock.nowMicros() + 500000;
    native.recordResult = {
      'path': f.path,
      'sampleRate': 16000,
      'firstSampleNanos': startLocal * 1000 + 7000000000 + 20000000, // 20 ms after start
      'timestampSource': 'audioTimestamp',
    };
    final rec = await b.calibrationRecorder(sampleRate: 16000).record(startAtLocalUs: startLocal, durationUs: 100000);
    final sent = native.calls['recordMic']!;
    expect(((sent[0] as int) - (startLocal * 1000 + 7000000000)).abs(), lessThan(100000));
    expect(sent[1], 100);
    expect(rec.sampleRate, 16000);
    expect(rec.samples.length, 1600);
    expect((rec.firstSampleLocalUs - (startLocal + 20000)).abs(), lessThan(100));
    expect(await f.exists(), isFalse, reason: 'recording file is deleted after decoding');

    native.micGranted = false;
    await expectLater(b.calibrationRecorder().record(startAtLocalUs: startLocal, durationUs: 100000),
        throwsA(isA<CalibrationRecorderException>()));
    await dir.delete(recursive: true);
    await b.dispose();
  });

  test('background playback skips identical notification updates', () async {
    final native = FakeNative(ManualClock(0), 0);
    final bg = BackgroundPlayback(api: native);
    await bg.update(title: 'x', text: 'y', playing: true);
    expect(native.calls['updateService'], isNull, reason: 'not started');
    await bg.start(title: 'Room', text: 'Song', playing: false);
    expect(native.calls['requestPermission'], ['notifications']);
    expect(native.calls['startService'], ['Room', 'Song', false]);
    await bg.update(title: 'Room', text: 'Song', playing: false);
    expect(native.calls['updateService'], isNull);
    await bg.update(title: 'Room', text: 'Song', playing: true);
    expect(native.calls['updateService'], ['Room', 'Song', true]);
    await bg.stop();
    expect(native.calls['stopService'], isEmpty);
    expect(bg.running, isFalse);
  });
}
