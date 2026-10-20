// Catalog browser UI with a fake catalog and a fake downloader.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncsphere/src/data/app_store.dart';
import 'package:syncsphere/src/data/models.dart';
import 'package:syncsphere/src/services/catalogs.dart';
import 'package:syncsphere/src/services/library_service.dart';
import 'package:syncsphere/src/services/remote_source.dart';
import 'package:syncsphere/src/state/providers.dart';
import 'package:syncsphere/src/ui/catalog_browser.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

void main() {
  testWidgets('catalog browser: search, open a collection, add all', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 2400);
    addTearDown(tester.view.reset);
    final store = MemoryAppStore();
    final remote = _FakeRemote(LibraryService(store: store, libraryDir: Directory.systemTemp, log: EventLog(clock: SystemMonotonicClock.instance)));
    late List<LibraryTrack> result;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appStoreProvider.overrideWithValue(store),
        archiveProvider.overrideWithValue(_FakeCatalog()),
        remoteSourceProvider.overrideWithValue(remote),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async => result = await showCatalog(context, archiveProvider),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Free concerts, albums and old recordings'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'live');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live 1977'));
    await tester.pumpAndSettle();
    expect(find.text('2 tracks · Band'), findsOneWidget);
    await tester.tap(find.text('Add all'));
    await tester.pumpAndSettle();
    expect(remote.fetched, ['https://a.example/1.mp3', 'https://a.example/2.mp3']);
    expect(find.byIcon(Icons.check_circle), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done (2)'));
    await tester.pumpAndSettle();
    expect(result.map((t) => t.title), ['One', 'Two']);
  });
}

class _FakeCatalog implements MusicCatalog {
  @override
  String get name => 'Internet Archive';
  @override
  String get hint => 'Artist';
  @override
  String get about => 'Free concerts, albums and old recordings';
  @override
  Future<CatalogResults> search(String query) async =>
      const CatalogResults(groups: [CatalogGroup(id: 'live77', title: 'Live 1977', subtitle: 'Band')]);
  @override
  Future<List<CatalogTrack>> open(CatalogGroup group) async => const [
        CatalogTrack(url: 'https://a.example/1.mp3', title: 'One', artist: 'Band', credit: 'via Internet Archive'),
        CatalogTrack(url: 'https://a.example/2.mp3', title: 'Two', artist: 'Band', credit: 'via Internet Archive'),
      ];
  @override
  void close() {}
}

class _FakeRemote extends RemoteSource {
  final List<String> fetched = [];
  _FakeRemote(LibraryService library) : super(library: library);
  @override
  Future<LibraryTrack> fetchToLibrary(String url,
      {String? title, String? artist, String? artUrl, String? credit, void Function(int, int?)? onProgress}) async {
    fetched.add(url);
    return LibraryTrack(
        id: url.hashCode.toRadixString(16).padLeft(64, '0'),
        path: '/dev/null',
        title: title ?? url,
        artist: artist,
        sizeBytes: 1,
        addedAt: DateTime(2026),
        sourceUrl: url,
        credit: credit);
  }
}
