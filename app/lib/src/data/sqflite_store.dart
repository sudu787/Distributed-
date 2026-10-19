import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'app_store.dart';
import 'models.dart';

/// SQLite-backed [AppStore].
class SqfliteAppStore implements AppStore {
  final Database db;
  SqfliteAppStore._(this.db);

  static const _version = 3;

  /// Opens (and migrates) the database at [path]. Pass a
  /// [DatabaseFactory] in tests (e.g. `databaseFactoryFfi`).
  static Future<SqfliteAppStore> open(String path, {DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onCreate: (db, version) async {
          final batch = db.batch()
            ..execute('CREATE TABLE device_config (key TEXT PRIMARY KEY, value TEXT NOT NULL)')
            ..execute('''
              CREATE TABLE library_tracks (
                id TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                title TEXT NOT NULL,
                artist TEXT,
                album TEXT,
                size INTEGER NOT NULL,
                duration_us INTEGER,
                mime TEXT,
                added_at INTEGER NOT NULL,
                source_url TEXT,
                art_url TEXT,
                credit TEXT
              )''')
            ..execute('''
              CREATE TABLE room_history (
                room_id TEXT NOT NULL,
                room_name TEXT NOT NULL,
                host TEXT NOT NULL,
                port INTEGER NOT NULL,
                hosted INTEGER NOT NULL,
                at INTEGER NOT NULL,
                join_key TEXT,
                PRIMARY KEY (room_id, at)
              )''');
          await batch.commit(noResult: true);
        },
        onUpgrade: (db, from, to) async {
          if (from < 2) {
            // v2: join key for one-tap rejoin from "Recent parties".
            await db.execute('ALTER TABLE room_history ADD COLUMN join_key TEXT');
          }
          if (from < 3) {
            // v3: songs from open catalogs / links remember their source.
            for (final c in ['source_url', 'art_url', 'credit']) {
              await db.execute('ALTER TABLE library_tracks ADD COLUMN $c TEXT');
            }
          }
        },
      ),
    );
    return SqfliteAppStore._(db);
  }

  Future<String?> _get(String key) async {
    final rows = await db.query('device_config', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> _set(String key, String value) =>
      db.insert('device_config', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<DeviceIdentity> loadIdentity({required String defaultName}) async {
    var id = await _get('device_id');
    if (id == null) {
      id = generateDeviceId();
      await _set('device_id', id);
    }
    return DeviceIdentity(
      deviceId: id,
      displayName: await _get('display_name') ?? defaultName,
      startLatencyUs: int.tryParse(await _get('start_latency_us') ?? '') ?? 0,
      outputCalibrationUs: int.tryParse(await _get('output_calibration_us') ?? '') ?? 0,
    );
  }

  @override
  Future<void> saveIdentity(DeviceIdentity i) async {
    await _set('display_name', i.displayName);
    await _set('start_latency_us', '${i.startLatencyUs}');
    await _set('output_calibration_us', '${i.outputCalibrationUs}');
  }

  @override
  Future<List<LibraryTrack>> libraryTracks() async =>
      (await db.query('library_tracks', orderBy: 'added_at')).map(LibraryTrack.fromRow).toList();

  @override
  Future<void> upsertTrack(LibraryTrack track) =>
      db.insert('library_tracks', track.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<void> deleteTrack(String id) => db.delete('library_tracks', where: 'id = ?', whereArgs: [id]);

  @override
  Future<List<RoomHistoryEntry>> roomHistory({int limit = kMaxRoomHistory}) async {
    // Older versions kept one row per visit; show each party once.
    final rows = await db.query('room_history', orderBy: 'at DESC');
    final seen = <String>{};
    return [
      for (final e in rows.map(RoomHistoryEntry.fromRow))
        if (seen.add(e.roomId)) e,
    ].take(limit).toList();
  }

  @override
  Future<void> addRoomHistory(RoomHistoryEntry entry) => db.transaction((tx) async {
        await tx.delete('room_history', where: 'room_id = ?', whereArgs: [entry.roomId]);
        await tx.insert('room_history', entry.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
        await tx.rawDelete(
          'DELETE FROM room_history WHERE room_id NOT IN '
          '(SELECT room_id FROM room_history ORDER BY at DESC LIMIT ?)',
          [kMaxRoomHistory],
        );
      });

  @override
  Future<void> removeRoomHistory(String roomId) =>
      db.delete('room_history', where: 'room_id = ?', whereArgs: [roomId]);

  @override
  Future<String?> setting(String key) => _get('setting.$key');

  @override
  Future<void> saveSetting(String key, String value) => _set('setting.$key', value);

  @override
  Future<HostedRoom?> hostedRoom() async {
    final raw = await _get('hosted_room');
    if (raw == null || raw.isEmpty) return null;
    try {
      return HostedRoom.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> saveHostedRoom(HostedRoom? room) => _set('hosted_room', room == null ? '' : jsonEncode(room.toJson()));

  @override
  Future<void> close() => db.close();
}
