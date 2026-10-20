import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../data/models.dart';
import 'library_service.dart';

/// A song in the phone's own music collection (Android MediaStore).
class DeviceSong {
  final String uri;
  final String title;
  final String? artist;
  final String? album;
  final int albumId;
  final Duration? duration;
  final int size;
  final String? fileName;
  const DeviceSong({
    required this.uri,
    required this.title,
    this.artist,
    this.album,
    this.albumId = 0,
    this.duration,
    this.size = 0,
    this.fileName,
  });

  static DeviceSong? fromMap(Map<String, Object?> m) {
    final uri = m['uri'];
    if (uri is! String || uri.isEmpty) return null;
    final name = m['name'] is String ? m['name'] as String : null;
    final title = m['title'] is String ? m['title'] as String : null;
    final dur = m['durationMs'];
    return DeviceSong(
      uri: uri,
      title: title ?? (name == null ? 'Unknown song' : _stem(name)),
      artist: m['artist'] is String ? m['artist'] as String : null,
      album: m['album'] is String ? m['album'] as String : null,
      albumId: m['albumId'] is int ? m['albumId'] as int : 0,
      duration: dur is num && dur > 0 ? Duration(milliseconds: dur.round()) : null,
      size: m['size'] is int ? m['size'] as int : 0,
      fileName: name,
    );
  }

  bool matches(String q) {
    final s = q.toLowerCase();
    return title.toLowerCase().contains(s) ||
        (artist?.toLowerCase().contains(s) ?? false) ||
        (album?.toLowerCase().contains(s) ?? false);
  }
}

/// Audio shared to SyncSphere from another app.
class SharedAudio {
  final String uri;
  final String name;
  const SharedAudio(this.uri, this.name);
}

String _stem(String name) => name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;

/// The phone's music collection and "Share → SyncSphere". Platform calls are
/// injected (Android: NativeAudioApi), so tests use plain functions.
class DeviceMedia {
  final Future<bool> Function()? _requestAccess;
  final Future<List<Map<String, Object?>>> Function()? _query;
  final Future<int> Function(String uri, String outPath)? _copy;
  final Future<List<Map<String, Object?>>> Function()? _takeShared;
  final Future<bool> Function(String uri, String outPath)? _artwork;
  final Directory? _artDir;

  /// Fires when audio is shared to the app while it runs.
  final Stream<void> shareArrived;

  DeviceMedia({
    required Future<bool> Function() requestAccess,
    required Future<List<Map<String, Object?>>> Function() query,
    required Future<int> Function(String uri, String outPath) copy,
    required Future<List<Map<String, Object?>>> Function() takeShared,
    Future<bool> Function(String uri, String outPath)? artwork,
    Directory? artDir,
    Stream<void>? shareArrived,
  })  : _requestAccess = requestAccess,
        _query = query,
        _copy = copy,
        _takeShared = takeShared,
        _artwork = artwork,
        _artDir = artDir,
        shareArrived = shareArrived ?? const Stream.empty();

  /// No phone library (desktop builds, tests that do not need it).
  DeviceMedia.none()
      : _requestAccess = null,
        _query = null,
        _copy = null,
        _takeShared = null,
        _artwork = null,
        _artDir = null,
        shareArrived = const Stream.empty();

  bool get available => _query != null;

  /// Asks for read access to the music collection; true when granted.
  Future<bool> requestAccess() async => _requestAccess == null ? false : await _requestAccess();

  Future<List<DeviceSong>> songs() async {
    final q = _query;
    if (q == null) return const [];
    return [for (final m in await q()) if (DeviceSong.fromMap(m) case final s?) s];
  }

  /// Album cover for [song] (cached per album), or null.
  final Map<int, Future<File?>> _art = {};
  Future<File?> artworkFor(DeviceSong song) {
    final extract = _artwork, dir = _artDir;
    if (extract == null || dir == null) return Future.value(null);
    final key = song.albumId == 0 ? song.uri.hashCode : song.albumId;
    return _art[key] ??= () async {
      final f = File('${dir.path}/album-$key.jpg');
      if (await f.exists()) return f;
      await dir.create(recursive: true);
      try {
        return await extract(song.uri, f.path) ? f : null;
      } catch (_) {
        return null;
      }
    }();
  }

  /// Copies a phone song (or a shared file) into My music.
  Future<LibraryTrack> import(LibraryService library, String uri,
      {String? title, String? artist, String? fileName}) async {
    final copy = _copy;
    if (copy == null) throw StateError('no phone library on this device');
    await library.libraryDir.create(recursive: true);
    final ext = _ext(fileName);
    final tmp = File('${library.libraryDir.path}/.device-${Random().nextInt(1 << 32)}$ext');
    try {
      await copy(uri, tmp.path);
      return await library.import(tmp,
          displayName: fileName == null ? null : _stem(fileName), title: title, artist: artist);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  /// Audio shared since the last call.
  Future<List<SharedAudio>> takeShared() async {
    final t = _takeShared;
    if (t == null) return const [];
    return [
      for (final m in await t())
        if (m['uri'] is String) SharedAudio(m['uri'] as String, m['name'] is String ? m['name'] as String : 'Shared song'),
    ];
  }

  static String _ext(String? name) {
    if (name == null || !name.contains('.')) return '';
    final e = name.substring(name.lastIndexOf('.')).toLowerCase();
    return e.length <= 6 ? e : '';
  }
}
