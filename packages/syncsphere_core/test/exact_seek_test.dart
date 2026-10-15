import 'dart:io';

import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

void main() {
  test('sniffs MP3 (ID3 or frame sync) and ADTS, not WAV/FLAC/MP4/Ogg', () {
    expect(needsExactSeekCopy('ID3'.codeUnits), isTrue);
    expect(needsExactSeekCopy([0xFF, 0xFB, 0x90]), isTrue); // MPEG-1 Layer III
    expect(needsExactSeekCopy([0xFF, 0xF1, 0x50]), isTrue); // ADTS AAC
    expect(needsExactSeekCopy('RIFF'.codeUnits), isFalse);
    expect(needsExactSeekCopy('fLaC'.codeUnits), isFalse);
    expect(needsExactSeekCopy('OggS'.codeUnits), isFalse);
    expect(needsExactSeekCopy([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70]), isFalse); // MP4 "ftyp"
    expect(needsExactSeekCopy([]), isFalse);
  });

  group('ConvertingTrackResolver', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('ss-exact'));
    tearDown(() async => tmp.delete(recursive: true));

    TrackInfo track(String id) => TrackInfo(id: id * 64, title: id, durationUs: 1000000, sizeBytes: 10);

    test('converts once, reuses the copy, and dedupes concurrent requests', () async {
      final a = track('a');
      var calls = 0;
      final r = ConvertingTrackResolver(
        inner: StaticTrackResolver({a.id: Uri.file('${tmp.path}/a.mp3')}),
        log: EventLog(clock: ManualClock()),
        convert: (t, src) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          final f = File('${tmp.path}/${t.title}.wav')..writeAsStringSync('pcm');
          return f.uri;
        },
      );
      final both = await Future.wait([r.resolve(a, DistributionMode.auto), r.resolve(a, DistributionMode.auto)]);
      expect(both.map((s) => s.uri.path), everyElement(endsWith('a.wav')));
      expect((await r.resolve(a, DistributionMode.auto)).uri.path, endsWith('a.wav'));
      expect(calls, 1);
    });

    test('falls back to the original on conversion failure or null', () async {
      final a = track('a'), b = track('b');
      final log = EventLog(clock: ManualClock());
      final r = ConvertingTrackResolver(
        inner: StaticTrackResolver({a.id: Uri.file('/x/a.mp3'), b.id: Uri.file('/x/b.flac')}),
        log: log,
        convert: (t, src) async => t.title == 'a' ? throw StateError('decoder broke') : null,
      );
      expect((await r.resolve(a, DistributionMode.auto)).uri.path, '/x/a.mp3');
      expect((await r.resolve(b, DistributionMode.auto)).uri.path, '/x/b.flac');
      expect(log.recent().any((e) => e.category == 'track.exact' && e.message.contains('seeks may be inexact')), isTrue);
    });

    test('warm converts only tracks already on the device', () async {
      final a = track('a'), b = track('b');
      final converted = <String>[];
      final r = ConvertingTrackResolver(
        inner: StaticTrackResolver({a.id: Uri.file('/x/a.mp3')}),
        log: EventLog(clock: ManualClock()),
        convert: (t, src) async {
          converted.add(t.title);
          return (File('${tmp.path}/${t.title}.wav')..writeAsStringSync('pcm')).uri;
        },
      );
      await r.warm([a, b], DistributionMode.auto);
      expect(converted, ['a']);
    });
  });
}
