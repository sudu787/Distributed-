import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncsphere_audio/syncsphere_audio.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import 'src/app.dart';
import 'src/data/sqflite_store.dart';
import 'src/services/library_service.dart';
import 'src/services/room_service.dart';
import 'src/state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  final cache = await getApplicationCacheDirectory();
  final store = await SqfliteAppStore.open(p.join(docs.path, 'syncsphere.db'));
  final identity = await store.loadIdentity(defaultName: _defaultName());
  final clock = SystemMonotonicClock.instance;
  final log = EventLog(clock: clock, source: 'app', capacity: 3000);
  if (kDebugMode) {
    log.printer = (src, e) {
      if (e.level.index >= EventLevel.info.index) debugPrint('$src $e');
    };
  }

  final native = Platform.isAndroid ? MethodChannelAudioApi() : null;
  final library = LibraryService(
    store: store,
    libraryDir: Directory(p.join(docs.path, 'library')),
    prober: native?.probe,
    log: log,
  );
  final rooms = RoomService(
    store: store,
    cacheDir: cache,
    clock: clock,
    log: log,
    hooks: native == null ? const NoopPlatformHooks() : _AndroidHooks(native, log),
    backendFactory: (log) async {
      if (native == null) {
        // Desktop/dev builds: follow the timeline without rendering audio.
        return NullAudioBackend(clock.nowMicros);
      }
      final b = Media3AudioBackend(api: native, clock: clock, log: log);
      await b.initialize();
      if (b.deviceInfo['bluetoothOutputPresent'] == true) {
        log.warn('audio.bluetooth',
            'Bluetooth output detected: its latency is not visible to sync estimates; calibrate acoustically.');
      }
      return b;
    },
  );

  runApp(ProviderScope(
    overrides: [
      appStoreProvider.overrideWithValue(store),
      libraryServiceProvider.overrideWithValue(library),
      roomServiceProvider.overrideWithValue(rooms),
      initialIdentityProvider.overrideWithValue(identity),
    ],
    child: const SyncSphereApp(),
  ));
}

String _defaultName() {
  final host = Platform.localHostname;
  if (host.isEmpty || host == 'localhost') return Platform.isAndroid ? 'Android phone' : 'SyncSphere device';
  return host;
}

class _AndroidHooks implements PlatformHooks {
  final NativeAudioApi api;
  final EventLog log;
  _AndroidHooks(this.api, this.log);

  @override
  Future<void> enterRoom() async {
    try {
      final locks = await api.acquireNetworkLocks();
      log.info('platform.locks', 'network locks acquired', locks);
      await api.keepScreenOn(true);
    } catch (e) {
      log.warn('platform.locks', 'could not acquire network locks: $e');
    }
  }

  @override
  Future<void> leaveRoom() async {
    try {
      await api.releaseNetworkLocks();
      await api.keepScreenOn(false);
    } catch (e) {
      log.warn('platform.locks', 'could not release network locks: $e');
    }
  }
}
