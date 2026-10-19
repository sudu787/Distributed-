import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../data/app_store.dart';
import '../data/models.dart';
import '../services/artwork_service.dart';
import '../services/audius_client.dart';
import '../services/remote_source.dart';
import '../services/library_service.dart';
import '../services/network_info.dart';
import '../services/room_service.dart';

/// Overridden in `main()` with the opened store / services.
final appStoreProvider = Provider<AppStore>((ref) => throw UnimplementedError('override appStoreProvider'));
final libraryServiceProvider =
    Provider<LibraryService>((ref) => throw UnimplementedError('override libraryServiceProvider'));
final roomServiceProvider = Provider<RoomService>((ref) => throw UnimplementedError('override roomServiceProvider'));
/// Open music sources: the Audius catalog and plain links.
final audiusClientProvider = Provider<AudiusClient>((ref) {
  final c = AudiusClient();
  ref.onDispose(c.close);
  return c;
});
final remoteSourceProvider = Provider<RemoteSource>((ref) {
  final r = RemoteSource(library: ref.watch(libraryServiceProvider));
  ref.onDispose(r.close);
  return r;
});

/// Album art; overridden in `main()` (disabled in tests).
final artworkServiceProvider = Provider<ArtworkService>((ref) => ArtworkService.disabled());

/// The cover of a track, or null (placeholder). While the song is still
/// downloading to this phone it checks again every few seconds.
final artworkProvider = FutureProvider.autoDispose.family<File?, String>((ref, trackId) async {
  final svc = ref.watch(artworkServiceProvider);
  final art = await svc.artFor(trackId);
  if (art == null && await svc.mayAppearLater(trackId)) {
    final retry = Timer(const Duration(seconds: 3), ref.invalidateSelf);
    ref.onDispose(retry.cancel);
  }
  return art;
});

final initialIdentityProvider =
    Provider<DeviceIdentity>((ref) => throw UnimplementedError('override initialIdentityProvider'));

/// Device identity and calibration, persisted on change.
class IdentityNotifier extends Notifier<DeviceIdentity> {
  @override
  DeviceIdentity build() => ref.watch(initialIdentityProvider);

  Future<void> update(DeviceIdentity next) async {
    state = next;
    await ref.read(appStoreProvider).saveIdentity(next);
  }
}

final identityProvider = NotifierProvider<IdentityNotifier, DeviceIdentity>(IdentityNotifier.new);

/// The device's track library.
class LibraryNotifier extends AsyncNotifier<List<LibraryTrack>> {
  @override
  Future<List<LibraryTrack>> build() => ref.read(libraryServiceProvider).list();

  /// Imports files; returns per-file errors (empty on full success).
  Future<List<String>> importFiles(List<File> files) async {
    final svc = ref.read(libraryServiceProvider);
    final errors = <String>[];
    for (final f in files) {
      try {
        await svc.import(f);
      } catch (e) {
        errors.add('${f.uri.pathSegments.last}: $e');
      }
    }
    state = AsyncData(await svc.list());
    return errors;
  }

  Future<void> remove(LibraryTrack t) async {
    final svc = ref.read(libraryServiceProvider);
    await svc.remove(t);
    state = AsyncData(await svc.list());
  }
}

final libraryProvider = AsyncNotifierProvider<LibraryNotifier, List<LibraryTrack>>(LibraryNotifier.new);

final roomHistoryProvider = FutureProvider<List<RoomHistoryEntry>>((ref) => ref.read(appStoreProvider).roomHistory());

/// The party this phone created and has not ended (for "Rejoin your party").
final hostedRoomProvider = FutureProvider<HostedRoom?>((ref) => ref.read(appStoreProvider).hostedRoom());

final networkSummaryProvider = FutureProvider<NetworkSummary>((ref) => readNetworkSummary());

/// Live list of rooms announced on the LAN. Listening stops when no screen
/// watches it.
final discoveryProvider = StreamProvider.autoDispose<List<RoomBeacon>>((ref) {
  final d = RoomDiscovery();
  final ctl = StreamController<List<RoomBeacon>>();
  StreamSubscription<List<RoomBeacon>>? sub;
  ctl.add(const []);
  Future<void> start() async {
    try {
      await d.start();
      sub = d.rooms.listen(ctl.add);
    } catch (e) {
      ctl.addError('Discovery unavailable: $e');
    }
  }

  unawaited(start());
  ref.onDispose(() async {
    await sub?.cancel();
    await d.stop();
    await ctl.close();
  });
  return ctl.stream;
});
