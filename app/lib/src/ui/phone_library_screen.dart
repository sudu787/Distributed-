import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../services/device_media.dart';
import '../state/providers.dart';
import 'format.dart';
import 'haptics.dart';
import 'widgets.dart';

/// Opens the phone's music collection; returns the songs added to My music.
Future<List<LibraryTrack>> showPhoneLibrary(BuildContext context) async =>
    await Navigator.of(context)
        .push<List<LibraryTrack>>(MaterialPageRoute(builder: (_) => const PhoneLibraryScreen())) ??
    const [];

/// Songs, albums and artists on this phone, with search and multi-select.
/// Chosen songs are copied into My music (and from there into a party).
class PhoneLibraryScreen extends ConsumerStatefulWidget {
  const PhoneLibraryScreen({super.key});

  @override
  ConsumerState<PhoneLibraryScreen> createState() => _PhoneLibraryScreenState();
}

enum _Access { checking, denied, granted }

class _PhoneLibraryScreenState extends ConsumerState<PhoneLibraryScreen> {
  _Access _access = _Access.checking;
  List<DeviceSong> _songs = const [];
  String? _error;
  final _query = TextEditingController();
  final Set<String> _picked = {};
  (int, int)? _importing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final media = ref.read(deviceMediaProvider);
    setState(() {
      _access = _Access.checking;
      _error = null;
    });
    if (!await media.requestAccess()) {
      if (mounted) setState(() => _access = _Access.denied);
      return;
    }
    try {
      final songs = await media.songs();
      if (mounted) {
        setState(() {
          _songs = songs;
          _access = _Access.granted;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _access = _Access.granted;
          _error = 'Could not read the music on this phone: $e';
        });
      }
    }
  }

  List<DeviceSong> get _filtered {
    final q = _query.text.trim();
    return q.isEmpty ? _songs : _songs.where((s) => s.matches(q)).toList();
  }

  void _toggle(DeviceSong s) {
    haptic(ref, Haptic.tap);
    setState(() => _picked.contains(s.uri) ? _picked.remove(s.uri) : _picked.add(s.uri));
  }

  void _toggleAll(Iterable<DeviceSong> songs) {
    haptic(ref, Haptic.tap);
    final uris = songs.map((s) => s.uri).toSet();
    setState(() => _picked.containsAll(uris) ? _picked.removeAll(uris) : _picked.addAll(uris));
  }

  Future<void> _import() async {
    final media = ref.read(deviceMediaProvider);
    final lib = ref.read(libraryServiceProvider);
    final chosen = [for (final s in _songs) if (_picked.contains(s.uri)) s];
    if (chosen.isEmpty) return;
    haptic(ref, Haptic.action);
    final added = <LibraryTrack>[];
    final failed = <String>[];
    for (final (i, s) in chosen.indexed) {
      if (!mounted) return;
      setState(() => _importing = (i, chosen.length));
      try {
        added.add(await media.import(lib, s.uri, title: s.title, artist: s.artist, fileName: s.fileName));
      } catch (e) {
        failed.add(s.title);
      }
    }
    ref.invalidate(libraryProvider);
    if (!mounted) return;
    setState(() => _importing = null);
    if (failed.isNotEmpty) {
      haptic(ref, Haptic.alert);
      showMessage(context, 'Could not copy: ${failed.join(', ')}', error: true);
    }
    Navigator.of(context).pop(added);
  }

  @override
  Widget build(BuildContext context) {
    final importing = _importing;
    final songs = _filtered;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Music on this phone'),
          bottom: _access == _Access.granted
              ? const TabBar(tabs: [Tab(text: 'Songs'), Tab(text: 'Albums'), Tab(text: 'Artists')])
              : null,
        ),
        body: switch (_access) {
          _Access.checking => const Center(child: CircularProgressIndicator()),
          _Access.denied => _NoAccess(onRetry: _load),
          _Access.granted => Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search ${_songs.length} songs',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(_query.clear),
                          ),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
              Expanded(
                child: _songs.isEmpty && _error == null
                    ? const _Empty()
                    : TabBarView(children: [
                        _SongList(songs: songs, picked: _picked, onToggle: _toggle, onToggleAll: _toggleAll),
                        _GroupList(
                          songs: songs,
                          keyOf: (s) => s.album ?? 'Unknown album',
                          subtitleOf: (list) =>
                              '${list.first.artist ?? 'Unknown artist'} · ${list.length} song${list.length == 1 ? '' : 's'}',
                          icon: Icons.album_outlined,
                          picked: _picked,
                          onOpen: _openGroup,
                        ),
                        _GroupList(
                          songs: songs,
                          keyOf: (s) => s.artist ?? 'Unknown artist',
                          subtitleOf: (list) => '${list.length} song${list.length == 1 ? '' : 's'}',
                          icon: Icons.person_outline,
                          picked: _picked,
                          onOpen: _openGroup,
                        ),
                      ]),
              ),
            ]),
        },
        bottomNavigationBar: _picked.isEmpty
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: importing != null
                      ? Column(mainAxisSize: MainAxisSize.min, children: [
                          Text('Copying ${importing.$1 + 1} of ${importing.$2}…'),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(value: importing.$1 / importing.$2),
                        ])
                      : Row(children: [
                          TextButton(onPressed: () => setState(_picked.clear), child: const Text('Clear')),
                          const Spacer(),
                          FilledButton.icon(
                            icon: const Icon(Icons.add),
                            label: Text('Add ${_picked.length} song${_picked.length == 1 ? '' : 's'}'),
                            onPressed: _import,
                          ),
                        ]),
                ),
              ),
      ),
    );
  }

  Future<void> _openGroup(String title, List<DeviceSong> songs) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => StatefulBuilder(
          builder: (context, setLocal) => Scaffold(
            appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
            body: _SongList(
              songs: songs,
              picked: _picked,
              onToggle: (s) {
                _toggle(s);
                setLocal(() {});
              },
              onToggleAll: (all) {
                _toggleAll(all);
                setLocal(() {});
              },
            ),
            bottomNavigationBar: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(_picked.isEmpty ? 'Back' : 'Done · ${_picked.length} selected'),
                ),
              ),
            ),
          ),
        ),
      )).then((_) => setState(() {}));
}

class _SongList extends ConsumerWidget {
  final List<DeviceSong> songs;
  final Set<String> picked;
  final void Function(DeviceSong) onToggle;
  final void Function(Iterable<DeviceSong>) onToggleAll;
  const _SongList({required this.songs, required this.picked, required this.onToggle, required this.onToggleAll});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (songs.isEmpty) return const Center(child: Text('No songs match.'));
    final all = songs.every((s) => picked.contains(s.uri));
    return ListView.builder(
      itemCount: songs.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return CheckboxListTile(
            value: all,
            onChanged: (_) => onToggleAll(songs),
            title: Text(all ? 'Unselect all' : 'Select all (${songs.length})'),
            controlAffinity: ListTileControlAffinity.leading,
          );
        }
        final s = songs[i - 1];
        return CheckboxListTile(
          value: picked.contains(s.uri),
          onChanged: (_) => onToggle(s),
          controlAffinity: ListTileControlAffinity.leading,
          secondary: _DeviceArt(song: s),
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [s.artist ?? 'Unknown artist', if (s.duration != null) fmtClock(s.duration!.inMicroseconds)].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }
}

class _GroupList extends StatelessWidget {
  final List<DeviceSong> songs;
  final String Function(DeviceSong) keyOf;
  final String Function(List<DeviceSong>) subtitleOf;
  final IconData icon;
  final Set<String> picked;
  final Future<void> Function(String title, List<DeviceSong> songs) onOpen;
  const _GroupList({
    required this.songs,
    required this.keyOf,
    required this.subtitleOf,
    required this.icon,
    required this.picked,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<DeviceSong>>{};
    for (final s in songs) {
      (groups[keyOf(s)] ??= []).add(s);
    }
    final names = groups.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (names.isEmpty) return const Center(child: Text('No songs match.'));
    return ListView.builder(
      itemCount: names.length,
      itemBuilder: (context, i) {
        final list = groups[names[i]]!;
        final chosen = list.where((s) => picked.contains(s.uri)).length;
        return ListTile(
          leading: _DeviceArt(song: list.first, fallback: icon),
          title: Text(names[i], maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(subtitleOf(list), maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: chosen == 0
              ? const Icon(Icons.chevron_right)
              : Chip(label: Text('$chosen selected'), visualDensity: VisualDensity.compact),
          onTap: () => onOpen(names[i], list),
        );
      },
    );
  }
}

/// Album cover of a phone song (cached per album), or a placeholder.
class _DeviceArt extends ConsumerStatefulWidget {
  final DeviceSong song;
  final IconData fallback;
  const _DeviceArt({required this.song, this.fallback = Icons.music_note});

  @override
  ConsumerState<_DeviceArt> createState() => _DeviceArtState();
}

class _DeviceArtState extends ConsumerState<_DeviceArt> {
  late Future<File?> _art = ref.read(deviceMediaProvider).artworkFor(widget.song);

  @override
  void didUpdateWidget(_DeviceArt old) {
    super.didUpdateWidget(old);
    if (old.song.uri != widget.song.uri) _art = ref.read(deviceMediaProvider).artworkFor(widget.song);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<File?>(
      future: _art,
      builder: (context, snap) => ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox.square(
          dimension: 44,
          child: snap.data != null
              ? Image.file(snap.data!, fit: BoxFit.cover, gaplessPlayback: true)
              : ColoredBox(color: cs.surfaceContainerHighest, child: Icon(widget.fallback, color: cs.onSurfaceVariant)),
        ),
      ),
    );
  }
}

class _NoAccess extends StatelessWidget {
  final VoidCallback onRetry;
  const _NoAccess({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.library_music_outlined, size: 48, color: cs.primary),
          const SizedBox(height: 12),
          Text('Allow access to your music', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'SyncSphere only reads the songs you pick and copies them into My music. Nothing is uploaded except to '
            'the phones in your party.\n\nIf you said no before, allow "Music and audio" in the app settings, or use '
            '"Pick files…" instead.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Allow access')),
        ]),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('No music found on this phone. Download songs, or use "Pick files…" for Drive, Dropbox or '
              'other apps.', textAlign: TextAlign.center),
        ),
      );
}
