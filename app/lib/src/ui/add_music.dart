import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../services/audius_client.dart';
import '../state/providers.dart';
import 'format.dart';
import 'haptics.dart';
import 'widgets.dart';

/// Opens Audius search; returns the songs added to My music.
Future<List<LibraryTrack>> showAudiusSearch(BuildContext context) async =>
    await Navigator.of(context).push<List<LibraryTrack>>(MaterialPageRoute(builder: (_) => const AudiusSearchScreen())) ??
    const [];

/// Asks for a direct link to an audio file and adds it to My music.
Future<LibraryTrack?> addFromLink(BuildContext context, WidgetRef ref) async {
  final ctl = TextEditingController();
  final url = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Add from a link'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'Link to an audio file', hintText: 'https://…/song.mp3'),
        ),
        const SizedBox(height: 8),
        Text(
          'A direct link to a music file: your own Navidrome or Jellyfin server, a podcast episode, or free music. '
          'Every phone in the party downloads it from there.',
          style: Theme.of(c).textTheme.bodySmall,
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Add')),
      ],
    ),
  );
  if (url == null || url.isEmpty || !context.mounted) return null;
  final progress = ValueNotifier<double?>(null);
  final nav = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      content: ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (c, v, _) => Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Downloading…'),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: v),
        ]),
      ),
    ),
  );
  try {
    final t = await ref.read(remoteSourceProvider).fetchToLibrary(url,
        onProgress: (got, total) => progress.value = total == null || total == 0 ? null : got / total);
    nav.pop();
    ref.invalidate(libraryProvider);
    return t;
  } catch (e) {
    nav.pop();
    if (context.mounted) {
      haptic(ref, Haptic.alert);
      showMessage(context, '$e', error: true);
    }
    return null;
  } finally {
    progress.dispose();
  }
}

/// Search the free Audius catalog and add songs to My music. Each song
/// keeps its Audius stream URL, so in a party every phone downloads it from
/// Audius (the host is only a fallback) and the artist is credited.
class AudiusSearchScreen extends ConsumerStatefulWidget {
  const AudiusSearchScreen({super.key});

  @override
  ConsumerState<AudiusSearchScreen> createState() => _AudiusSearchScreenState();
}

class _AudiusSearchScreenState extends ConsumerState<AudiusSearchScreen> {
  final _query = TextEditingController();
  List<AudiusTrack>? _results;
  String? _error;
  bool _searching = false;
  final Map<String, double?> _downloading = {};
  final Map<String, LibraryTrack> _added = {};

  @override
  void dispose() {
    _query.dispose();
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
      final r = await ref.read(audiusClientProvider).search(q);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _add(AudiusTrack t) async {
    if (_downloading.containsKey(t.id) || _added.containsKey(t.id)) return;
    haptic(ref, Haptic.action);
    setState(() => _downloading[t.id] = null);
    final audius = ref.read(audiusClientProvider);
    try {
      final lib = await ref.read(remoteSourceProvider).fetchToLibrary(
            audius.streamUrl(t.id),
            title: t.title,
            artist: t.artist,
            artUrl: t.artUrl,
            credit: 'via Audius',
            onProgress: (got, total) {
              if (mounted && total != null && total > 0) setState(() => _downloading[t.id] = got / total);
            },
          );
      _added[t.id] = lib;
      ref.invalidate(libraryProvider);
    } catch (e) {
      if (mounted) {
        haptic(ref, Haptic.alert);
        showMessage(context, 'Could not add "${t.title}": $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _downloading.remove(t.id));
    }
  }

  void _close() => Navigator.of(context).pop(_added.values.toList());

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final results = _results;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _close),
          title: const Text('Search Audius'),
          actions: [
            if (_added.isNotEmpty)
              TextButton(onPressed: _close, child: Text('Done (${_added.length})')),
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
                hintText: 'Song or artist',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), tooltip: 'Search', onPressed: _search),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (_searching) const LinearProgressIndicator(),
          Expanded(
            child: _error != null
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
                : results == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text('Free music from independent artists on Audius.', style: t.bodyMedium, textAlign: TextAlign.center),
                        ),
                      )
                    : results.isEmpty
                        ? const Center(child: Text('No songs found.'))
                        : ListView.builder(
                            itemCount: results.length,
                            itemBuilder: (c, i) {
                              final r = results[i];
                              final busy = _downloading.containsKey(r.id);
                              final done = _added.containsKey(r.id);
                              return ListTile(
                                leading: TrackArt(null, size: 48, url: r.artUrl),
                                title: Text(r.title, overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                    '${r.artist}${r.duration == null ? '' : ' · ${fmtClock(r.duration!.inMicroseconds)}'}',
                                    overflow: TextOverflow.ellipsis),
                                trailing: done
                                    ? const Icon(Icons.check_circle, color: Colors.green)
                                    : busy
                                        ? SizedBox.square(
                                            dimension: 24,
                                            child: CircularProgressIndicator(strokeWidth: 3, value: _downloading[r.id]))
                                        : IconButton(
                                            tooltip: 'Add',
                                            icon: const Icon(Icons.add_circle_outline),
                                            onPressed: () => _add(r),
                                          ),
                                onTap: done || busy ? null : () => _add(r),
                              );
                            },
                          ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Music from Audius; artists are credited. Every phone downloads the song from Audius, so phones in a '
                'party need internet for these songs (the host is a fallback).',
                style: t.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
