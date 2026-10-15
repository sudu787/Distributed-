import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../data/app_store.dart';
import '../data/models.dart';
import '../services/library_service.dart';
import '../services/network_info.dart';
import '../services/room_service.dart';

/// Overridden in `main()` with the opened store / services.
final appStoreProvider = Provider<AppStore>((ref) => throw UnimplementedError('override appStoreProvider'));
final libraryServiceProvider =
    Provider<LibraryService>((ref) => throw UnimplementedError('override libraryServiceProvider'));
final roomServiceProvider = Provider<RoomService>((ref) => throw UnimplementedError('override roomServiceProvider'));
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
