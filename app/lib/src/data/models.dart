import 'package:syncsphere_core/syncsphere_core.dart';

/// A verified audio file in this device's library. [id] is the SHA-256 of
/// its content, which is what makes it matchable across devices.
class LibraryTrack {
  final String id;
  final String path;
  final String title;
  final String? artist;
  final String? album;
  final int sizeBytes;
  final int? durationUs;
  final String? mimeType;
  final DateTime addedAt;

  const LibraryTrack({
    required this.id,
    required this.path,
    required this.title,
    this.artist,
    this.album,
    required this.sizeBytes,
    this.durationUs,
    this.mimeType,
    required this.addedAt,
  });

  TrackInfo toTrackInfo() => TrackInfo(
        id: id,
        title: title,
        artist: artist,
        album: album,
        durationUs: durationUs,
        sizeBytes: sizeBytes,
        mimeType: mimeType,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'path': path,
        'title': title,
        'artist': artist,
        'album': album,
        'size': sizeBytes,
        'duration_us': durationUs,
        'mime': mimeType,
        'added_at': addedAt.millisecondsSinceEpoch,
      };

  factory LibraryTrack.fromRow(Map<String, Object?> r) => LibraryTrack(
        id: r['id']! as String,
        path: r['path']! as String,
        title: r['title']! as String,
        artist: r['artist'] as String?,
        album: r['album'] as String?,
        sizeBytes: r['size']! as int,
        durationUs: r['duration_us'] as int?,
        mimeType: r['mime'] as String?,
        addedAt: DateTime.fromMillisecondsSinceEpoch(r['added_at']! as int),
      );
}

/// Persistent identity and per-device calibration.
class DeviceIdentity {
  final String deviceId;
  final String displayName;

  /// Learned play-call → audible delay (µs).
  final int startLatencyUs;

  /// Acoustic calibration offset (µs), see PlaybackEngine.outputCalibrationUs.
  final int outputCalibrationUs;

  const DeviceIdentity({
    required this.deviceId,
    required this.displayName,
    this.startLatencyUs = 0,
    this.outputCalibrationUs = 0,
  });

  DeviceIdentity copyWith({String? displayName, int? startLatencyUs, int? outputCalibrationUs}) => DeviceIdentity(
        deviceId: deviceId,
        displayName: displayName ?? this.displayName,
        startLatencyUs: startLatencyUs ?? this.startLatencyUs,
        outputCalibrationUs: outputCalibrationUs ?? this.outputCalibrationUs,
      );
}

/// How many recent parties the app remembers.
const kMaxRoomHistory = 5;

/// A party this phone was in, newest first in the "Recent parties" list.
/// [joinKey] lets the phone rejoin with one tap while the party is still
/// running; it is stored only in app-private storage (null for entries
/// saved by older versions).
class RoomHistoryEntry {
  final String roomId;
  final String roomName;
  final String host;
  final int port;
  final bool hosted;
  final DateTime at;
  final String? joinKey;

  const RoomHistoryEntry({
    required this.roomId,
    required this.roomName,
    required this.host,
    required this.port,
    required this.hosted,
    required this.at,
    this.joinKey,
  });

  Map<String, Object?> toRow() => {
        'room_id': roomId,
        'room_name': roomName,
        'host': host,
        'port': port,
        'hosted': hosted ? 1 : 0,
        'at': at.millisecondsSinceEpoch,
        'join_key': joinKey,
      };

  factory RoomHistoryEntry.fromRow(Map<String, Object?> r) => RoomHistoryEntry(
        roomId: r['room_id']! as String,
        roomName: r['room_name']! as String,
        host: r['host']! as String,
        port: r['port']! as int,
        hosted: (r['hosted']! as int) == 1,
        at: DateTime.fromMillisecondsSinceEpoch(r['at']! as int),
        joinKey: r['join_key'] as String?,
      );
}

/// The party this device created, remembered so the host can rejoin (and get
/// the host role back) after the app was closed or crashed. Contains the
/// join key; stored only in app-private storage.
class HostedRoom {
  final String roomId;
  final String roomName;
  final String joinKey;
  final DateTime startedAt;
  const HostedRoom({required this.roomId, required this.roomName, required this.joinKey, required this.startedAt});

  Map<String, Object?> toJson() =>
      {'room': roomId, 'name': roomName, 'key': joinKey, 'at': startedAt.millisecondsSinceEpoch};

  static HostedRoom? fromJson(Map<String, Object?> j) {
    final room = j['room'], name = j['name'], key = j['key'], at = j['at'];
    if (room is! String || name is! String || key is! String || at is! int) return null;
    return HostedRoom(roomId: room, roomName: name, joinKey: key, startedAt: DateTime.fromMillisecondsSinceEpoch(at));
  }
}
