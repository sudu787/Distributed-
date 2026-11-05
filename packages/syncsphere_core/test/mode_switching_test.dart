import 'dart:async';
import 'dart:io';

import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

/// Records calls; can be told to fail on start.
class _FakeBackend implements AudioBackend {
  final String name;
  final Set<SyncEngineMode> engines;
  final bool schedulesOutput;
  final calls = <String>[];
  final StreamController<AudioBackendEvent> ctl = StreamController.broadcast(sync: true);
  Object? failStart;
  _FakeBackend(this.name, this.engines, {this.schedulesOutput = false});

  @override
  AudioCapabilities get capabilities =>
      AudioCapabilities(backend: name, rateControl: true, schedulesOutput: schedulesOutput);
  @override
  Set<SyncEngineMode> get supportedEngines => engines;
  @override
  Future<SyncEngineMode> useEngine(SyncEngineMode mode, FeatureFlags flags) async {
    calls.add('use:${mode.name}${flags.keepAwake ? '' : ':noawake'}');
    if (mode == SyncEngineMode.precise && failStart != null) throw failStart!;
    return engines.contains(mode) ? mode : SyncEngineMode.classic;
  }

  @override
  Future<void> prepare({required int segmentId, required TrackSource source, required int positionUs}) async =>
      calls.add('prepare:$segmentId');
  @override
  Future<void> startAt({required int segmentId, required int atLocalUs}) async => calls.add('start:$segmentId');
  @override
  Future<void> pauseAt({required int segmentId, required int atLocalUs, int? thenSeekToUs}) async =>
      calls.add('pause:$segmentId');
  @override
  Future<void> setRate(double rate) async => calls.add('rate:$rate');
  @override
  Future<void> setVolume(double volume) async => calls.add('volume:$volume');
  @override
  Future<void> setChannelRole(ChannelRole role) async => calls.add('role:${role.name}');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<PositionSample?> samplePosition() async => null;
  @override
  Stream<AudioBackendEvent> get events => ctl.stream;
  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await ctl.close();
  }
}

void main() {
  late _FakeBackend exo;
  late _FakeBackend pcm;
  late ModeSwitchingBackend sw;
  setUp(() {
    exo = _FakeBackend('exo', {SyncEngineMode.classic, SyncEngineMode.warm});
    pcm = _FakeBackend('pcm', {SyncEngineMode.precise}, schedulesOutput: true);
    sw = ModeSwitchingBackend(classic: exo, precise: pcm);
  });
  tearDown(() => sw.dispose());

  test('routes calls to the selected engine and reports its capabilities', () async {
    expect(sw.supportedEngines, SyncEngineMode.values.toSet());
    expect(await sw.useEngine(SyncEngineMode.precise, const FeatureFlags()), SyncEngineMode.precise);
    expect(sw.capabilities.schedulesOutput, isTrue);
    await sw.prepare(segmentId: 1, source: TrackSource(uri: Uri.parse('file:///a.wav'), trackId: 'a'), positionUs: 0);
    await sw.startAt(segmentId: 1, atLocalUs: 5);
    expect(pcm.calls, containsAllInOrder(['use:precise', 'prepare:1', 'start:1']));
    expect(exo.calls, ['use:classic'], reason: 'ExoPlayer is stopped (and keep-awake off) while precise runs');

    expect(await sw.useEngine(SyncEngineMode.warm, const FeatureFlags()), SyncEngineMode.warm);
    expect(pcm.calls.last, 'use:classic', reason: 'leaving precise releases the renderer');
    await sw.startAt(segmentId: 2, atLocalUs: 5);
    expect(exo.calls.last, 'start:2');
    expect(sw.capabilities.schedulesOutput, isFalse);
  });

  test('volume and channel role reach both engines so a switch keeps them', () async {
    await sw.setVolume(0.4);
    await sw.setChannelRole(ChannelRole.left);
    expect(exo.calls, ['volume:0.4', 'role:left']);
    expect(pcm.calls, ['volume:0.4', 'role:left']);
  });

  test('a renderer that cannot start falls back to Classic, unless fallback is off', () async {
    pcm.failStart = const AudioBackendException('engine_unavailable', 'no output');
    expect(await sw.useEngine(SyncEngineMode.precise, const FeatureFlags()), SyncEngineMode.classic);
    expect(identical(sw.current, exo), isTrue);
    expect(sw.requested, SyncEngineMode.precise);
    await expectLater(sw.useEngine(SyncEngineMode.precise, const FeatureFlags(preciseFallback: false)),
        throwsA(isA<AudioBackendException>()));
  });

  test('a renderer failing while playing hands over to Classic and says so', () async {
    await sw.useEngine(SyncEngineMode.precise, const FeatureFlags());
    final seen = <AudioEventKind>[];
    sw.events.listen((e) => seen.add(e.kind));
    pcm.ctl.add(const AudioBackendEvent(AudioEventKind.playCalled, 3, 10));
    exo.ctl.add(const AudioBackendEvent(AudioEventKind.playCalled, 9, 10)); // not current: dropped
    pcm.ctl.add(const AudioBackendEvent(AudioEventKind.engineFallback, -1, 20, 'write failed'));
    await Future<void>.delayed(Duration.zero);
    expect(seen, [AudioEventKind.playCalled, AudioEventKind.engineFallback]);
    expect(identical(sw.current, exo), isTrue);
    exo.ctl.add(const AudioBackendEvent(AudioEventKind.ended, 4, 30));
    expect(seen.last, AudioEventKind.ended);
  });

  test('with fallback off, a renderer failure is reported as an error and nothing switches', () async {
    await sw.useEngine(SyncEngineMode.precise, const FeatureFlags(preciseFallback: false));
    final seen = <AudioBackendEvent>[];
    sw.events.listen(seen.add);
    pcm.ctl.add(const AudioBackendEvent(AudioEventKind.engineFallback, -1, 20, 'write failed'));
    expect(seen.single.kind, AudioEventKind.error);
    expect(identical(sw.current, pcm), isTrue);
  });

  test('without a renderer, precise means Classic', () async {
    final only = ModeSwitchingBackend(classic: exo);
    expect(only.supportedEngines, {SyncEngineMode.classic, SyncEngineMode.warm});
    expect(await only.useEngine(SyncEngineMode.precise, const FeatureFlags()), SyncEngineMode.classic);
  });

  group('PCM WAV check', () {
    List<int> wav({int format = 1, int bits = 16, int channels = 2, bool listFirst = false}) {
      final b = <int>[];
      void tag(String s) => b.addAll(s.codeUnits);
      void u16(int v) => b.addAll([v & 255, v >> 8 & 255]);
      void u32(int v) => b.addAll([v & 255, v >> 8 & 255, v >> 16 & 255, v >> 24 & 255]);
      tag('RIFF');
      u32(100);
      tag('WAVE');
      if (listFirst) {
        tag('LIST');
        u32(3);
        b.addAll([1, 2, 3, 0]); // odd size + pad byte
      }
      tag('fmt ');
      u32(16);
      u16(format);
      u16(channels);
      u32(44100);
      u32(44100 * channels * bits ~/ 8);
      u16(channels * bits ~/ 8);
      u16(bits);
      tag('data');
      u32(0);
      return b;
    }

    test('accepts 16-bit PCM, rejects other encodings and non-WAV files', () {
      expect(isPlayablePcmWav(wav()), isTrue);
      expect(isPlayablePcmWav(wav(listFirst: true, channels: 1)), isTrue);
      expect(isPlayablePcmWav(wav(bits: 24)), isFalse);
      expect(isPlayablePcmWav(wav(format: 3, bits: 32)), isFalse, reason: 'float WAV gets decoded');
      expect(isPlayablePcmWav('ID3....'.codeUnits), isFalse);
      expect(isPlayablePcmWav(const []), isFalse);
    });

    test('the warm-start probe clip and calibration clicks are playable as they are', () async {
      final dir = await Directory.systemTemp.createTemp('syncsphere-probe');
      try {
        final src = await silentProbeTrack(dir);
        final head = await readFileHead(File.fromUri(src.uri), 64);
        expect(isPlayablePcmWav(head), isTrue);
        expect(await File.fromUri(src.uri).length(), 44 + 48000 * 7 ~/ 2 * 2);
        final again = await silentProbeTrack(dir);
        expect(again.uri, src.uri, reason: 'written once, reused');
        const plan = CalibrationPlan.syncCheck(id: 1, listener: 'a', order: ['a']);
        final click = await FileCalibrationTrackFactory(dir).sourceFor(plan, 0);
        expect(isPlayablePcmWav(await readFileHead(File.fromUri(click.uri), 64)), isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
