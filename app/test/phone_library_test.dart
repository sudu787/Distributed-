// "Music on this phone" and "Share → SyncSphere" with fake platform calls.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncsphere/src/data/app_store.dart';
import 'package:syncsphere/src/data/models.dart';
import 'package:syncsphere/src/services/device_media.dart';
import 'package:syncsphere/src/services/library_service.dart';
import 'package:syncsphere/src/state/providers.dart';
import 'package:syncsphere/src/ui/phone_library_screen.dart';
import 'package:syncsphere/src/ui/share_receiver.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

const _songs = [
  {'uri': 'content://media/1', 'title': 'Blue Hour', 'artist': 'Nova', 'album': 'Night', 'albumId': 7, 'durationMs': 215000, 'size': 10, 'name': 'blue.mp3'},
  {'uri': 'content://media/2', 'title': 'Red Sky', 'artist': 'Nova', 'album': 'Night', 'albumId': 7, 'durationMs': 180000, 'size': 10, 'name': 'red.flac'},
  {'uri': 'content://media/3', 'artist': 'Lumen', 'album': 'Day', 'albumId': 8, 'durationMs': 200000, 'size': 10, 'name': 'Sunrise.ogg'},
  {'title': 'no uri'},
];

DeviceMedia _media({
  required Future<bool> Function() access,
  List<Map<String, Object?>> shared = const [],
  List<String>? copied,
}) {
  var pending = [...shared];
  return DeviceMedia(
    requestAccess: access,
    query: () async => _songs,
    copy: (uri, out) async {
      copied?.add(uri);
      await File(out).writeAsString('audio of $uri');
      return 1;
    },
    takeShared: () async {
      final r = pending;
      pending = [];
      return r;
    },
  );
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('syncsphere_device'));
  tearDown(() async => tmp.delete(recursive: true));
  LibraryService lib(MemoryAppStore store) =>
      LibraryService(store: store, libraryDir: Directory('${tmp.path}/lib'), log: EventLog(clock: SystemMonotonicClock.instance));

  test('songs are parsed; copying a phone song imports it into My music', () async {
    final copied = <String>[];
    final media = _media(access: () async => true, copied: copied);
    final songs = await media.songs();
    expect(songs.map((s) => s.title), ['Blue Hour', 'Red Sky', 'Sunrise']);
    expect(songs.first.duration, const Duration(seconds: 215));
    expect(songs.first.matches('nov'), isTrue);
    expect(songs.last.matches('night'), isFalse);

    final store = MemoryAppStore();
    final t = await media.import(lib(store), songs[1].uri, title: 'Red Sky', artist: 'Nova', fileName: 'red.flac');
    expect(copied, ['content://media/2']);
    expect(t.title, 'Red Sky');
    expect(t.path, endsWith('.flac'));
    expect(File(t.path).readAsStringSync(), 'audio of content://media/2');
    expect(Directory('${tmp.path}/lib').listSync().where((e) => e.path.contains('.device-')), isEmpty);
    expect(DeviceMedia.none().available, isFalse);
  });

  testWidgets('phone library: ask for access, search, pick songs, add', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 1600);
    addTearDown(tester.view.reset);
    final store = MemoryAppStore();
    var grant = false;
    final copied = <String>[];
    final media = _media(access: () async => grant, copied: copied);
    late List<LibraryTrack> result;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appStoreProvider.overrideWithValue(store),
        libraryServiceProvider.overrideWithValue(lib(store)),
        deviceMediaProvider.overrideWithValue(media),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () async => result = await showPhoneLibrary(context), child: const Text('open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Allow access to your music'), findsOneWidget);

    grant = true;
    await tester.tap(find.text('Allow access'));
    await tester.pumpAndSettle();
    expect(find.text('Blue Hour'), findsOneWidget);
    expect(find.text('Sunrise'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nova');
    await tester.pumpAndSettle();
    expect(find.text('Sunrise'), findsNothing);
    await tester.tap(find.text('Select all (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Add 2 songs'), findsOneWidget);

    // Albums tab shows the selection per album.
    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    expect(find.text('Night'), findsOneWidget);
    expect(find.text('2 selected'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Add 2 songs'));
      for (var i = 0; i < 50 && copied.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(copied, ['content://media/1', 'content://media/2']);
    expect(result.map((t) => t.title), ['Blue Hour', 'Red Sky']);
  });

  testWidgets('share receiver: shared audio lands in My music with a message', (tester) async {
    final store = MemoryAppStore();
    final media = _media(access: () async => true, shared: [
      {'uri': 'content://downloads/9', 'name': 'Field Recording.mp3'},
    ]);
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          appStoreProvider.overrideWithValue(store),
          libraryServiceProvider.overrideWithValue(lib(store)),
          deviceMediaProvider.overrideWithValue(media),
        ],
        child: const MaterialApp(home: ShareReceiver(child: Scaffold(body: Text('home')))),
      ));
      for (var i = 0; i < 50 && (await store.libraryTracks()).isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect((await store.libraryTracks()).single.title, 'Field Recording');
    expect(find.text('Added 1 song to My music.'), findsOneWidget);
  });
}
