import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import '../state/room_controller.dart';
import 'haptics.dart';

/// "Share → SyncSphere": audio shared from a file manager, downloader or
/// messenger is copied into My music; in a party it can go straight into the
/// queue. Checks at start, when a share arrives while running, and on resume.
class ShareReceiver extends ConsumerStatefulWidget {
  final Widget child;
  const ShareReceiver({super.key, required this.child});

  @override
  ConsumerState<ShareReceiver> createState() => _ShareReceiverState();
}

class _ShareReceiverState extends ConsumerState<ShareReceiver> with WidgetsBindingObserver {
  StreamSubscription<void>? _sub;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = ref.read(deviceMediaProvider).shareArrived.listen((_) => _check());
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (_busy || !mounted) return;
    _busy = true;
    try {
      final media = ref.read(deviceMediaProvider);
      final shared = await media.takeShared();
      if (shared.isEmpty || !mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(
        content: Text('Adding ${shared.length} shared song${shared.length == 1 ? '' : 's'}…'),
        duration: const Duration(seconds: 2),
      ));
      final lib = ref.read(libraryServiceProvider);
      final added = <LibraryTrack>[];
      final failed = <String>[];
      for (final s in shared) {
        try {
          added.add(await media.import(lib, s.uri, fileName: s.name));
        } catch (e) {
          failed.add(s.name);
        }
      }
      ref.invalidate(libraryProvider);
      if (!mounted) return;
      haptic(ref, failed.isEmpty ? Haptic.action : Haptic.alert);
      final room = ref.read(roomControllerProvider);
      final canQueue = room.canControl && added.isNotEmpty;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text([
          if (added.isNotEmpty) 'Added ${added.length} song${added.length == 1 ? '' : 's'} to My music.',
          if (failed.isNotEmpty) 'Could not read: ${failed.join(', ')}.',
        ].join(' ')),
        action: canQueue
            ? SnackBarAction(
                label: 'Add to queue',
                onPressed: () async {
                  final err = await ref.read(roomControllerProvider.notifier).addTracks(added);
                  if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
                },
              )
            : null,
      ));
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
