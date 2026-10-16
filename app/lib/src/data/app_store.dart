import 'package:syncsphere_core/syncsphere_core.dart' show newId;

import 'models.dart';

/// Local persistence: device identity/calibration, library index and room
/// history. SQLite in the app ([SqfliteAppStore]); in-memory in tests.
abstract class AppStore {
  Future<DeviceIdentity> loadIdentity({required String defaultName});
  Future<void> saveIdentity(DeviceIdentity identity);

  Future<List<LibraryTrack>> libraryTracks();
  Future<void> upsertTrack(LibraryTrack track);
  Future<void> deleteTrack(String id);

  /// Recent parties, newest first (one entry per party).
  Future<List<RoomHistoryEntry>> roomHistory({int limit = kMaxRoomHistory});

  /// Records [entry], replacing an older entry for the same party, and
  /// keeps only the [kMaxRoomHistory] newest parties.
  Future<void> addRoomHistory(RoomHistoryEntry entry);
  Future<void> removeRoomHistory(String roomId);

  /// Small app preferences (e.g. vibration feedback).
  Future<String?> setting(String key);
  Future<void> saveSetting(String key, String value);

  /// The party this device hosts (null when none / ended on purpose).
  Future<HostedRoom?> hostedRoom();
  Future<void> saveHostedRoom(HostedRoom? room);

  Future<void> close();
}

/// Generates a device id compatible with the protocol's id rules.
String generateDeviceId() => 'dev-${newId(9).replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), 'x')}';

class MemoryAppStore implements AppStore {
  DeviceIdentity? _identity;
  final Map<String, LibraryTrack> _tracks = {};
  final List<RoomHistoryEntry> _history = [];
  HostedRoom? _hosted;
  final Map<String, String> _settings = {};

  @override
  Future<DeviceIdentity> loadIdentity({required String defaultName}) async =>
      _identity ??= DeviceIdentity(deviceId: generateDeviceId(), displayName: defaultName);

  @override
  Future<void> saveIdentity(DeviceIdentity identity) async => _identity = identity;

  @override
  Future<List<LibraryTrack>> libraryTracks() async =>
      _tracks.values.toList()..sort((a, b) => a.addedAt.compareTo(b.addedAt));

  @override
  Future<void> upsertTrack(LibraryTrack track) async => _tracks[track.id] = track;

  @override
  Future<void> deleteTrack(String id) async => _tracks.remove(id);

  @override
  Future<List<RoomHistoryEntry>> roomHistory({int limit = kMaxRoomHistory}) async =>
      (List.of(_history)..sort((a, b) => b.at.compareTo(a.at))).take(limit).toList();

  @override
  Future<void> addRoomHistory(RoomHistoryEntry entry) async {
    _history
      ..removeWhere((e) => e.roomId == entry.roomId)
      ..add(entry)
      ..sort((a, b) => b.at.compareTo(a.at));
    if (_history.length > kMaxRoomHistory) _history.removeRange(kMaxRoomHistory, _history.length);
  }

  @override
  Future<void> removeRoomHistory(String roomId) async => _history.removeWhere((e) => e.roomId == roomId);

  @override
  Future<String?> setting(String key) async => _settings[key];

  @override
  Future<void> saveSetting(String key, String value) async => _settings[key] = value;

  @override
  Future<HostedRoom?> hostedRoom() async => _hosted;

  @override
  Future<void> saveHostedRoom(HostedRoom? room) async => _hosted = room;

  @override
  Future<void> close() async {}
}
