import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../data/models.dart';
import '../services/catalogs.dart';
import '../state/providers.dart';
import 'format.dart';
import 'haptics.dart';
import 'widgets.dart';

/// Opens a free online catalog (Openverse, Internet Archive, podcasts);
/// returns the songs added to My music.
Future<List<LibraryTrack>> showCatalog(BuildContext context, ProviderListenable<MusicCatalog> catalog) async =>
    await Navigator.of(context)
        .push<List<LibraryTrack>>(MaterialPageRoute(builder: (_) => CatalogBrowserScreen(catalog: catalog))) ??
    const [];

/// Downloads chosen tracks into My music and remembers progress, shared by
/// the search screen and the screens of opened collections.
class _Adder extends ChangeNotifier {
  final Map<String, double?> downloading = {};
  final Map<String, LibraryTrack> added = {};

  Future<void> add(WidgetRef ref, BuildContext context, CatalogTrack t) async {
    if (downloading.containsKey(t.url) || added.containsKey(t.url)) return;
    haptic(ref, Haptic.action);
    downloading[t.url] = null;
    notifyListeners();
    try {
      final lib = await ref.read(remoteSourceProvider).fetchToLibrary(
            t.url,
            title: t.title,
            artist: t.artist,
            artUrl: t.artUrl,
            credit: t.credit,
            onProgress: (got, total) {
              if (total != null && total > 0) {
                downloading[t.url] = got / total;
                notifyListeners();
              }
            },
          );
      added[t.url] = lib;
      ref.invalidate(libraryProvider);
    } catch (e) {
      if (context.mounted) {
        haptic(ref, Haptic.alert);
        showMessage(context, 'Could not add "${t.title}": $e', error: true);
      }
    } finally {
      downloading.remove(t.url);
      notifyListeners();
    }
  }
}

class CatalogBrowserScreen extends ConsumerStatefulWidget {
  final ProviderListenable<MusicCatalog> catalog;
  const CatalogBrowserScreen({super.key, required this.catalog});

  @override
  ConsumerState<CatalogBrowserScreen> createState() => _CatalogBrowserScreenState();
}

class _CatalogBrowserScreenState extends ConsumerState<CatalogBrowserScreen> {
  final _query = TextEditingController();
  final _adder = _Adder();
  CatalogResults? _results;
  String? _error;
  bool _searching = false;

  @override
  void dispose() {
    _query.dispose();
    _adder.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final r = await ref.read(widget.catalog).search(q);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _close() => Navigator.of(context).pop(_adder.added.values.toList());

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(widget.catalog);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final results = _results;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: ListenableBuilder(
        listenable: _adder,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            leading: BackButton(onPressed: _close),
            title: Text(catalog.name),
            actions: [
              if (_adder.added.isNotEmpty) TextButton(onPressed: _close, child: Text('Done (${_adder.added.length})')),
            ],
          ),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: catalog.hint,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), tooltip: 'Search', onPressed: _search),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            if (_searching) const LinearProgressIndicator(),
            Expanded(
              child: _error != null
                  ? _Message(icon: Icons.cloud_off, text: _error!)
                  : results == null
                      ? _Message(icon: Icons.travel_explore, text: catalog.about)
                      : results.isEmpty
                          ? const _Message(icon: Icons.search_off, text: 'Nothing found. Try other words.')
                          : ListView(children: [
                              for (final g in results.groups)
                                ListTile(
                                  leading: TrackArt(null, size: 48, url: g.artUrl),
                                  title: Text(g.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  subtitle: g.subtitle == null || g.subtitle!.isEmpty
                                      ? null
                                      : Text(g.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                                      builder: (_) => _GroupScreen(catalog: widget.catalog, group: g, adder: _adder))),
                                ),
                              for (final x in results.tracks) _TrackRow(track: x, adder: _adder),
                            ]),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  'Every phone in a party downloads these songs from ${catalog.name}, so phones need internet for them '
                  '(the host is a fallback). Credits and licences stay with each song.',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The tracks of one Internet Archive item or podcast.
class _GroupScreen extends ConsumerStatefulWidget {
  final ProviderListenable<MusicCatalog> catalog;
  final CatalogGroup group;
  final _Adder adder;
  const _GroupScreen({required this.catalog, required this.group, required this.adder});

  @override
  ConsumerState<_GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends ConsumerState<_GroupScreen> {
  late Future<List<CatalogTrack>> _tracks = ref.read(widget.catalog).open(widget.group);

  Future<void> _addAll(List<CatalogTrack> tracks) async {
    for (final x in tracks) {
      if (!mounted) return;
      await widget.adder.add(ref, context, x);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.group.title, overflow: TextOverflow.ellipsis)),
      body: FutureBuilder<List<CatalogTrack>>(
        future: _tracks,
        builder: (context, snap) {
          if (snap.hasError) {
            return _Message(
              icon: Icons.cloud_off,
              text: '${snap.error}',
              action: TextButton(
                onPressed: () => setState(() => _tracks = ref.read(widget.catalog).open(widget.group)),
                child: const Text('Try again'),
              ),
            );
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final tracks = snap.data!;
          if (tracks.isEmpty) return const _Message(icon: Icons.music_off, text: 'No playable audio here.');
          return ListenableBuilder(
            listenable: widget.adder,
            builder: (context, _) {
              final remaining = tracks.where((x) => !widget.adder.added.containsKey(x.url)).toList();
              return ListView(children: [
                ListTile(
                  leading: TrackArt(null, size: 56, url: widget.group.artUrl),
                  title: Text(widget.group.title, style: t.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${tracks.length} ${tracks.length == 1 ? 'track' : 'tracks'}'
                      '${widget.group.subtitle == null || widget.group.subtitle!.isEmpty ? '' : ' · ${widget.group.subtitle}'}'),
                  trailing: remaining.isEmpty
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : FilledButton.tonal(
                          onPressed: widget.adder.downloading.isEmpty ? () => _addAll(remaining) : null,
                          child: Text(remaining.length == tracks.length ? 'Add all' : 'Add ${remaining.length}'),
                        ),
                ),
                const Divider(height: 1),
                for (final x in tracks) _TrackRow(track: x, adder: widget.adder),
              ]);
            },
          );
        },
      ),
    );
  }
}

class _TrackRow extends ConsumerWidget {
  final CatalogTrack track;
  final _Adder adder;
  const _TrackRow({required this.track, required this.adder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = adder.downloading.containsKey(track.url);
    final done = adder.added.containsKey(track.url);
    final details = [
      track.artist,
      if (track.duration != null) fmtClock(track.duration!.inMicroseconds),
      if (track.detail != null) track.detail!,
    ].join(' · ');
    return ListTile(
      leading: TrackArt(null, size: 48, url: track.artUrl),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$details\n${track.credit}', maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: true,
      trailing: done
          ? const Icon(Icons.check_circle, color: Colors.green)
          : busy
              ? SizedBox.square(
                  dimension: 24, child: CircularProgressIndicator(strokeWidth: 3, value: adder.downloading[track.url]))
              : IconButton(
                  tooltip: 'Add',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => adder.add(ref, context, track),
                ),
      onTap: done || busy ? null : () => adder.add(ref, context, track),
      onLongPress: track.infoUrl == null
          ? null
          : () {
              Clipboard.setData(ClipboardData(text: track.infoUrl!));
              showMessage(context, 'Copied the licence / source link.');
            },
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const _Message({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
          if (action != null) action!,
        ]),
      ),
    );
  }
}

/// Menu entries for the free online catalogs, keyed for [catalogFor].
List<Widget> catalogMenuTiles(BuildContext sheet) => [
      ListTile(
        leading: const Icon(Icons.library_music_outlined),
        title: const Text('Openverse'),
        subtitle: const Text('Creative Commons music from Jamendo, Wikimedia and more'),
        onTap: () => Navigator.pop(sheet, 'openverse'),
      ),
      ListTile(
        leading: const Icon(Icons.account_balance_outlined),
        title: const Text('Internet Archive'),
        subtitle: const Text('Free concerts, albums and old recordings'),
        onTap: () => Navigator.pop(sheet, 'archive'),
      ),
      ListTile(
        leading: const Icon(Icons.podcasts),
        title: const Text('Podcasts'),
        subtitle: const Text('Find a show and listen to an episode together'),
        onTap: () => Navigator.pop(sheet, 'podcast'),
      ),
    ];

/// The catalog behind a [catalogMenuTiles] choice (null for other choices).
ProviderListenable<MusicCatalog>? catalogFor(String? choice) => switch (choice) {
      'openverse' => openverseProvider,
      'archive' => archiveProvider,
      'podcast' => podcastProvider,
      _ => null,
    };
