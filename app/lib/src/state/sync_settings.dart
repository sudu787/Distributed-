import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../data/app_store.dart';
import 'providers.dart';

/// Settings keys (stored with [AppStore.saveSetting]; no database schema
/// change, so an older build can still be installed over this one).
const kFeatureFlagsSetting = 'feature_flags';
const kHostEngineSetting = 'sync_engine';

Future<FeatureFlags> loadFeatureFlags(AppStore store) async {
  final raw = await store.setting(kFeatureFlagsSetting);
  if (raw == null) return const FeatureFlags();
  try {
    return FeatureFlags.fromJson(jsonDecode(raw));
  } on FormatException {
    return const FeatureFlags();
  }
}

Future<SyncEngineMode> loadHostEngine(AppStore store) async =>
    SyncEngineMode.parse(await store.setting(kHostEngineSetting));

/// This phone's feature switches; changes apply at once and are saved.
class FeatureFlagsNotifier extends Notifier<FeatureFlags> {
  @override
  FeatureFlags build() => ref.read(roomServiceProvider).flags;

  Future<void> set(FeatureFlags f) async {
    state = f;
    ref.read(roomServiceProvider).updateFlags(f);
    await ref.read(appStoreProvider).saveSetting(kFeatureFlagsSetting, jsonEncode(f.toJson()));
  }
}

final featureFlagsProvider = NotifierProvider<FeatureFlagsNotifier, FeatureFlags>(FeatureFlagsNotifier.new);

/// The sync engine this phone uses when it hosts (and, in its own party,
/// switches to now).
class HostEngineNotifier extends Notifier<SyncEngineMode> {
  @override
  SyncEngineMode build() => ref.read(roomServiceProvider).hostEngine;

  /// Returns null on success, else the error.
  Future<String?> set(SyncEngineMode mode) async {
    final err = await ref.read(roomServiceProvider).setSyncEngine(mode);
    if (err != null) return err;
    state = mode;
    await ref.read(appStoreProvider).saveSetting(kHostEngineSetting, mode.name);
    return null;
  }
}

final hostEngineProvider = NotifierProvider<HostEngineNotifier, SyncEngineMode>(HostEngineNotifier.new);
