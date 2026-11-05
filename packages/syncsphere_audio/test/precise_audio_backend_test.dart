import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncsphere_audio/syncsphere_audio.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import 'media3_audio_backend_test.dart' show FakeNative;

class FakePrecise implements PreciseNativeApi {
  final FakeNative native;
  final calls = <String, List<Object?>>{};
  String? startError;
  Map<String, Object?>? nextSample;
  FakePrecise(this.native);

  @override
  Future<Map<String, Object?>> start() async {
    calls['start'] = [];
    return {'error': startError, 'outRate': 48000};
  }

  @override
  Future<void> release() async => calls['release'] = [];
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
  Future<void> setChannelRole(String role) async => calls['setChannelRole'] = [role];
  @override
  Future<void> stop() async => calls['stop'] = [];
  @override
  Future<Map<String, Object?>?> sample() async => nextSample;
}

Future<(Media3AudioBackend, PreciseAudioBackend, FakeNative, FakePrecise, ManualClock)> _setup(
    {SourceConverter? convert}) async {
  final clock = ManualClock(3000000);
  final native = FakeNative(clock, 9000000000); // native 9 s ahead
  final exo = Media3AudioBackend(api: native, clock: clock);
  await exo.initialize();
  final api = FakePrecise(native);
  final precise = PreciseAudioBackend(
      api: api, nativeEvents: native.events, bridge: exo.bridge, clock: clock, convert: convert);
  return (exo, precise, native, api, clock);
}

void main() {
  test('start: audible times go to the renderer in the native clock; output errors refuse the engine', () async {
    final (exo, precise, native, api, clock) = await _setup();
    expect(await precise.useEngine(SyncEngineMode.precise, const FeatureFlags()), SyncEngineMode.precise);
    expect(precise.capabilities.schedulesOutput, isTrue);
    final at = clock.nowMicros() + 250000;
    await precise.startAt(segmentId: 4, atLocalUs: at);
    expect(((api.calls['startAt']![1] as int) - (at * 1000 + 9000000000)).abs(), lessThan(100000));
    expect(await precise.useEngine(SyncEngineMode.classic, const FeatureFlags()), SyncEngineMode.classic);
    expect(api.calls.containsKey('release'), isTrue);

    api.startError = 'no audio output';
    await expectLater(precise.useEngine(SyncEngineMode.precise, const FeatureFlags()),
        throwsA(isA<AudioBackendException>()));
    await precise.dispose();
    await exo.dispose();
  });

  test('events: each backend takes only its own engine\'s events', () async {
    final (exo, precise, native, _, _) = await _setup();
    final exoEvents = <AudioEventKind>[];
    final preciseEvents = <AudioEventKind>[];
    final s1 = exo.events.listen((e) => exoEvents.add(e.kind));
    final s2 = precise.events.listen((e) => preciseEvents.add(e.kind));
    native.ev.add({'kind': 'playCalled', 'segment': 1, 'atNanos': native.native});
    native.ev.add({'kind': 'playCalled', 'segment': 2, 'atNanos': native.native, 'engine': 'precise'});
    native.ev.add({'kind': 'engineFallback', 'segment': -1, 'atNanos': native.native, 'engine': 'precise', 'message': 'x'});
    await Future<void>.delayed(Duration.zero);
    expect(exoEvents, [AudioEventKind.playCalled]);
    expect(preciseEvents, [AudioEventKind.playCalled, AudioEventKind.engineFallback]);
    await s1.cancel();
    await s2.cancel();
    await precise.dispose();
    await exo.dispose();
  });

  test('samples come back in the Dart clock with the timestamp flag', () async {
    final (exo, precise, native, api, clock) = await _setup();
    api.nextSample = {
      'segment': 7,
      'positionUs': 1234567,
      'atNanos': native.native,
      'playing': true,
      'rate': 1.001,
      'state': 'ready',
      'fromTimestamp': true,
    };
    final s = (await precise.samplePosition())!;
    expect(s.segmentId, 7);
    expect(s.fromAudioTimestamp, isTrue);
    expect((s.atLocalUs - clock.nowMicros()).abs(), lessThan(200));
    await precise.dispose();
    await exo.dispose();
  });

  test('prepare plays PCM WAV as is and decodes anything else first', () async {
    final dir = await Directory.systemTemp.createTemp('ss-precise');
    final wav = File('${dir.path}/a.wav')..writeAsBytesSync(encodeWav(Int16List(100), sampleRate: 48000));
    final mp3 = File('${dir.path}/b.mp3')..writeAsBytesSync([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 0]);
    final converted = File('${dir.path}/b.wav')..writeAsBytesSync(encodeWav(Int16List(100), sampleRate: 48000));
    var conversions = 0;
    final (exo, precise, _, api, _) = await _setup(convert: (t, s) async {
      conversions++;
      return converted.uri;
    });
    await precise.prepare(segmentId: 1, source: TrackSource(uri: wav.uri, trackId: 'a'), positionUs: 5);
    expect(api.calls['prepare'], [1, wav.uri.toString(), 5]);
    await precise.prepare(segmentId: 2, source: TrackSource(uri: mp3.uri, trackId: 'b'), positionUs: 0);
    expect(api.calls['prepare'], [2, converted.uri.toString(), 0]);
    expect(conversions, 1);
    await expectLater(
        precise.prepare(segmentId: 3, source: TrackSource(uri: Uri.parse('content://x/1'), trackId: 'c'), positionUs: 0),
        throwsA(isA<AudioBackendException>()));
    await precise.dispose();
    await exo.dispose();
    await dir.delete(recursive: true);
  });

  test('warm start keeps the speaker awake; Classic and leaving turn it off', () async {
    final (exo, precise, native, _, _) = await _setup();
    expect(await exo.useEngine(SyncEngineMode.warm, const FeatureFlags()), SyncEngineMode.warm);
    expect(native.calls['setKeepAwake'], [true]);
    expect(await exo.useEngine(SyncEngineMode.warm, const FeatureFlags(keepAwake: false)), SyncEngineMode.warm);
    expect(native.calls['setKeepAwake'], [false]);
    await exo.useEngine(SyncEngineMode.warm, const FeatureFlags());
    expect(await exo.useEngine(SyncEngineMode.precise, const FeatureFlags()), SyncEngineMode.classic,
        reason: 'the ExoPlayer backend does not render precise itself');
    expect(native.calls['setKeepAwake'], [false]);
    await exo.useEngine(SyncEngineMode.warm, const FeatureFlags());
    await exo.dispose();
    expect(native.calls['setKeepAwake'], [false], reason: 'dispose stops the silent output');
    await precise.dispose();
  });

  test('exoPlayerOf finds the ExoPlayer backend behind the engine switch', () async {
    final (exo, precise, _, _, _) = await _setup();
    final sw = ModeSwitchingBackend(classic: exo, precise: precise);
    expect(identical(exoPlayerOf(sw), exo), isTrue);
    expect(identical(exoPlayerOf(exo), exo), isTrue);
    expect(exoPlayerOf(NullAudioBackend(() => 0)), isNull);
    await sw.dispose();
  });
}
