/// Authoritative room state owned by the coordinator.
///
/// Two counters protect consistency:
///
/// * [RoomState.version] increases on *every* change (membership, playlist,
///   volume, timeline). Receivers ignore any state whose version is not
///   newer than the last one applied, which makes duplicated, delayed and
///   reordered snapshots harmless.
/// * [PlaybackTimeline.generation] increases on every playback-timeline
///   discontinuity (start, pause, resume, seek, track change, resync).
///   Reports, acknowledgements and scheduled actions are tagged with the
///   generation they belong to, so an action from an earlier generation can
///   never restart an old track.
library;

import '../protocol/reader.dart';
import 'calibration_plan.dart';

enum PlaybackStatus { idle, playing, paused }

/// Where participants obtain audio for the room's tracks.
enum DistributionMode {
  /// Every device must already have a byte-identical file (verified by
  /// SHA-256).
  localOnly,

  /// Use a local copy when present, otherwise download it from the host over
  /// the LAN before playback.
  auto,

  /// Always download from the host (useful for testing delivery).
  lanOnly,
}

/// The playback timeline: a linear map from coordinator time to track
/// position. All devices render the same function; only the clock
/// conversion differs per device.
class PlaybackTimeline {
  final int generation;
  final String? trackId;
  final PlaybackStatus status;

  /// Track position (µs) at [anchorCoordUs].
  final int anchorPositionUs;

  /// Coordinator monotonic time (µs) at which [anchorPositionUs] is (or was)
  /// rendered. For a scheduled start this is in the future. For `paused`
  /// it is the time the pause takes effect.
  final int anchorCoordUs;

  /// Nominal timeline rate (1.0). Per-device correction rates are *not*
  /// part of the timeline.
  final double rate;

  const PlaybackTimeline({
    required this.generation,
    required this.trackId,
    required this.status,
    required this.anchorPositionUs,
    required this.anchorCoordUs,
    this.rate = 1.0,
  });

  const PlaybackTimeline.idle()
      : generation = 0,
        trackId = null,
        status = PlaybackStatus.idle,
        anchorPositionUs = 0,
        anchorCoordUs = 0,
        rate = 1.0;

  bool get isPlaying => status == PlaybackStatus.playing;

  /// Position that should be audible at coordinator time [coordUs].
  int expectedPositionAt(int coordUs) {
    switch (status) {
      case PlaybackStatus.idle:
        return anchorPositionUs;
      case PlaybackStatus.paused:
        // Until the pause takes effect the previous segment keeps playing;
        // the participant handles that via its active segment. After the
        // pause the position is frozen.
        return anchorPositionUs;
      case PlaybackStatus.playing:
        if (coordUs <= anchorCoordUs) return anchorPositionUs;
        return anchorPositionUs + ((coordUs - anchorCoordUs) * rate).round();
    }
  }

  /// Coordinator time at which track position [positionUs] is rendered
  /// (only meaningful while playing).
  int coordTimeForPosition(int positionUs) =>
      anchorCoordUs + ((positionUs - anchorPositionUs) / rate).round();

  PlaybackTimeline copyWith({
    int? generation,
    String? trackId,
    PlaybackStatus? status,
    int? anchorPositionUs,
    int? anchorCoordUs,
    double? rate,
  }) =>
      PlaybackTimeline(
        generation: generation ?? this.generation,
        trackId: trackId ?? this.trackId,
        status: status ?? this.status,
        anchorPositionUs: anchorPositionUs ?? this.anchorPositionUs,
        anchorCoordUs: anchorCoordUs ?? this.anchorCoordUs,
        rate: rate ?? this.rate,
      );

  Map<String, Object?> toJson() => {
        'gen': generation,
        'track': trackId,
        'status': status.name,
        'posUs': anchorPositionUs,
        'atUs': anchorCoordUs,
        'rate': rate,
      };

  factory PlaybackTimeline.fromJson(Map<String, Object?> j) {
    final r = Reader(j, 'timeline');
    return PlaybackTimeline(
      generation: r.integer('gen', min: 0),
      trackId: r.optString('track', maxLength: 80),
      status: r.enumValue('status', PlaybackStatus.values),
      anchorPositionUs: r.integer('posUs', min: 0),
      anchorCoordUs: r.integer('atUs'),
      rate: r.number('rate', min: 0.25, max: 4.0),
    );
  }

  @override
  String toString() =>
      'Timeline(g$generation ${status.name} track=$trackId pos=${anchorPositionUs ~/ 1000}ms @${anchorCoordUs ~/ 1000}ms)';
}

/// A segment the coordinator has asked participants to prepare (buffer) but
/// not yet scheduled. Participants report `ready` for its generation.
class PendingSegment {
  final int generation;
  final String trackId;
  final int positionUs;

  /// True when the pending segment should start playing once ready (as
  /// opposed to being prepared paused, e.g. a seek while paused).
  final bool autoPlay;

  const PendingSegment({
    required this.generation,
    required this.trackId,
    required this.positionUs,
    this.autoPlay = true,
  });

  Map<String, Object?> toJson() => {
        'gen': generation,
        'track': trackId,
        'posUs': positionUs,
        'play': autoPlay,
      };

  factory PendingSegment.fromJson(Map<String, Object?> j) {
    final r = Reader(j, 'pending');
    return PendingSegment(
      generation: r.integer('gen', min: 0),
      trackId: r.string('track', maxLength: 80),
      positionUs: r.integer('posUs', min: 0),
      autoPlay: r.boolean('play'),
    );
  }
}

/// Metadata for a track offered to the room. [id] is the lowercase hex
/// SHA-256 of the file content and is the only identity that matters for
/// matching files across devices.
class TrackInfo {
  final String id;
  final String title;
  final String? artist;
  final String? album;
  final int? durationUs;
  final int sizeBytes;
  final String? mimeType;

  /// Whether the host can serve this file over the LAN.
  final bool hostServes;

  /// Number of connected participants that reported the track available.
  final int availableCount;

  /// Where the song can be downloaded directly (http/https), e.g. an open
  /// catalog such as Audius or the user's own music server. When set, every
  /// device fetches it from there first (the catalog streams to each
  /// listener) and falls back to the host. The SHA-256 [id] still decides.
  final String? sourceUrl;

  /// Cover image URL from the catalog (used when the file has no picture).
  final String? artUrl;

  /// Attribution shown with the song, e.g. "via Audius".
  final String? credit;

  /// SHA-256 over the track's chunk hashes (chunks.dart). Lets devices
  /// download chunks from each other and verify the chunk list from any
  /// peer. Null: whole-file download only.
  final String? chunkRoot;

  const TrackInfo({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    this.durationUs,
    required this.sizeBytes,
    this.mimeType,
    this.hostServes = true,
    this.availableCount = 0,
    this.sourceUrl,
    this.artUrl,
    this.credit,
    this.chunkRoot,
  });

  TrackInfo copyWith({int? availableCount, bool? hostServes, int? durationUs, String? chunkRoot}) =>
      TrackInfo(
        id: id,
        title: title,
        artist: artist,
        album: album,
        durationUs: durationUs ?? this.durationUs,
        sizeBytes: sizeBytes,
        mimeType: mimeType,
        hostServes: hostServes ?? this.hostServes,
        availableCount: availableCount ?? this.availableCount,
        sourceUrl: sourceUrl,
        artUrl: artUrl,
        credit: credit,
        chunkRoot: chunkRoot ?? this.chunkRoot,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (durationUs != null) 'durUs': durationUs,
        'size': sizeBytes,
        if (mimeType != null) 'mime': mimeType,
        'serves': hostServes,
        'avail': availableCount,
        if (sourceUrl != null) 'src': sourceUrl,
        if (artUrl != null) 'art': artUrl,
        if (credit != null) 'credit': credit,
        if (chunkRoot != null) 'croot': chunkRoot,
      };

  factory TrackInfo.fromJson(Map<String, Object?> j) {
    final r = Reader(j, 'track');
    final id = r.string('id', maxLength: 64);
    if (!isValidTrackId(id)) {
      throw r.error('id', 'must be 64 lowercase hex chars (SHA-256)');
    }
    return TrackInfo(
      id: id,
      title: r.string('title', maxLength: 256),
      artist: r.optString('artist', maxLength: 256),
      album: r.optString('album', maxLength: 256),
      durationUs: r.optInteger('durUs', min: 0),
      sizeBytes: r.integer('size', min: 0),
      mimeType: r.optString('mime', maxLength: 100),
      hostServes: r.optBoolean('serves') ?? false,
      availableCount: r.optInteger('avail', min: 0) ?? 0,
      sourceUrl: _optWebUrl(r, 'src'),
      artUrl: _optWebUrl(r, 'art'),
      credit: r.optString('credit', maxLength: 64),
      chunkRoot: _optHash(r, 'croot'),
    );
  }

  static String? _optHash(Reader r, String key) {
    final v = r.optString(key, maxLength: 64);
    if (v != null && !isValidTrackId(v)) throw r.error(key, 'must be 64 lowercase hex chars');
    return v;
  }

  static String? _optWebUrl(Reader r, String key) {
    final v = r.optString(key, maxLength: 1024);
    if (v == null) return null;
    if (!isWebUrl(v)) throw r.error(key, 'must be an http(s) URL');
    return v;
  }

  /// True for absolute http/https URLs with a host.
  static bool isWebUrl(String v) {
    final u = Uri.tryParse(v);
    return u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty;
  }

  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static bool isValidTrackId(String s) => _hex64.hasMatch(s);
}

/// What a device plays from a stereo source (experimental distributed
/// stereo). Phones usually have one loudspeaker, so `left`/`right` route a
/// single source channel to all of the device's outputs.
/// What a phone plays. Phones usually have one loudspeaker, so each phone
/// is one point of a stereo or surround layout.
///
/// [center], [surroundLeft] and [surroundRight] are the surround roles
/// (ITU-R BS.775 5.1 positions: 0°, ±110°). For stereo music they are
/// upmixed with a passive matrix (center = 0.707·(L+R), surround =
/// 0.707·(L−R) at −3 dB and [kSurroundDelayUs] later); 5.1 files play the
/// matching channel. Only used when every phone supports them
/// ([DeviceCapabilities.surround]).
enum ChannelRole {
  stereo,
  left,
  right,
  mono,
  center,
  surroundLeft,
  surroundRight;

  bool get isSurroundRole => this == center || this == surroundLeft || this == surroundRight;
  bool get isRear => this == surroundLeft || this == surroundRight;
}

/// Extra delay of the rear (surround) phones. Matrix decoders delay the
/// surround channels by 15–20 ms so the precedence (Haas) effect keeps
/// sounds anchored at the front; it also makes the rear phones tolerant of
/// millisecond-level sync error.
const kSurroundDelayUs = 15000;

/// Delay a phone adds because of its role (µs).
int roleDelayUs(ChannelRole r) => r.isRear ? kSurroundDelayUs : 0;

/// Room-wide repeat behaviour at the end of a track.
enum PlaylistRepeat { off, all, one }

enum ParticipantRole {
  /// The coordinator's own device. Full control, cannot be demoted.
  host,

  /// May issue playback commands.
  controller,

  /// Plays audio and may only change its own device volume.
  listener;

  bool get canControl => this != listener;
}

enum ConnectionStatus { connected, suspect, disconnected }

/// Track availability for one participant.
enum TrackAvailability { unknown, available, fetching, missing, mismatch }

/// Membership entry included in [RoomState]. Fast-changing sync metrics are
/// sent separately in diagnostics messages so they do not churn versions.
class ParticipantSummary {
  final String deviceId;
  final String displayName;
  final ParticipantRole role;
  final ConnectionStatus connection;
  final double volume;
  final TrackAvailability currentTrack;
  final bool canHost;

  /// `host:port` where this device would serve the room if promoted to
  /// coordinator (null when it is not a failover candidate).
  final String? endpoint;

  final ChannelRole channel;

  /// Acoustic calibration offset assigned by the last room calibration (µs),
  /// or null if the device was not calibrated in this room.
  final int? calibrationUs;

  /// `host:port` of this device's peer file server (phone-to-phone song
  /// sharing), or null.
  final String? peer;

  const ParticipantSummary({
    required this.deviceId,
    required this.displayName,
    required this.role,
    required this.connection,
    this.volume = 1.0,
    this.currentTrack = TrackAvailability.unknown,
    this.canHost = false,
    this.endpoint,
    this.channel = ChannelRole.stereo,
    this.calibrationUs,
    this.peer,
  });

  ParticipantSummary copyWith({
    ParticipantRole? role,
    ConnectionStatus? connection,
    double? volume,
    TrackAvailability? currentTrack,
    String? displayName,
  }) =>
      ParticipantSummary(
        deviceId: deviceId,
        displayName: displayName ?? this.displayName,
        role: role ?? this.role,
        connection: connection ?? this.connection,
        volume: volume ?? this.volume,
        currentTrack: currentTrack ?? this.currentTrack,
        canHost: canHost,
        endpoint: endpoint,
        channel: channel,
        calibrationUs: calibrationUs,
        peer: peer,
      );

  Map<String, Object?> toJson() => {
        'id': deviceId,
        'name': displayName,
        'role': role.name,
        'conn': connection.name,
        'vol': volume,
        'track': currentTrack.name,
        'canHost': canHost,
        if (endpoint != null) 'ep': endpoint,
        if (channel != ChannelRole.stereo) 'ch': channel.name,
        if (calibrationUs != null) 'cal': calibrationUs,
        if (peer != null) 'peer': peer,
      };

  factory ParticipantSummary.fromJson(Map<String, Object?> j) {
    final r = Reader(j, 'participant');
    return ParticipantSummary(
      deviceId: r.string('id', maxLength: 64),
      displayName: r.string('name', maxLength: 64),
      role: r.enumValue('role', ParticipantRole.values),
      connection: r.enumValue('conn', ConnectionStatus.values),
      volume: r.number('vol', min: 0, max: 1),
      currentTrack: r.enumValue('track', TrackAvailability.values),
      canHost: r.optBoolean('canHost') ?? false,
      endpoint: r.optString('ep', maxLength: 128),
      channel: r.optEnum('ch', ChannelRole.values) ?? ChannelRole.stereo,
      calibrationUs: r.optInteger('cal', min: -2000000, max: 2000000),
      peer: r.optString('peer', maxLength: 128),
    );
  }
}

/// "Which phone is this?": the coordinator asks [deviceId] to flash its
/// screen, show its channel and vibrate until [untilUs] (coordinator time).
/// [seq] increases with every request, so asking twice re-triggers it.
class IdentifyRequest {
  final String deviceId;
  final int seq;
  final int untilUs;
  const IdentifyRequest({required this.deviceId, required this.seq, required this.untilUs});

  Map<String, Object?> toJson() => {'dev': deviceId, 'seq': seq, 'until': untilUs};

  factory IdentifyRequest.fromJson(Map<String, Object?> j) {
    final r = Reader(j, 'identify');
    return IdentifyRequest(deviceId: r.string('dev', maxLength: 64), seq: r.integer('seq', min: 0), untilUs: r.integer('until'));
  }
}

/// Result of a surround calibration: phone positions (m) in an arbitrary
/// rotation with the [listener] somewhere in it (oriented on the listener's
/// phone by tapping the front and the left phone, see calibration/layout.dart),
/// click levels at the listener (dBFS) and the fit's RMS residual (m).
class SpeakerLayout {
  final int id;
  final String listener;
  final Map<String, (double, double)> positions;
  final Map<String, double> levelsDb;
  final double residualM;
  const SpeakerLayout({
    required this.id,
    required this.listener,
    required this.positions,
    this.levelsDb = const {},
    this.residualM = 0,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'listener': listener,
        'pos': {
          for (final e in positions.entries) e.key: [_r(e.value.$1), _r(e.value.$2)]
        },
        if (levelsDb.isNotEmpty) 'lvl': {for (final e in levelsDb.entries) e.key: _r(e.value)},
        'res': _r(residualM),
      };

  static double _r(double v) => (v * 1000).round() / 1000;

  factory SpeakerLayout.fromJson(Map<String, Object?> j) {
    final r = Reader(j, 'layout');
    final pos = <String, (double, double)>{};
    final raw = r.map('pos');
    if (raw.length > 64) throw r.error('pos', 'too many devices');
    raw.forEach((k, v) {
      if (k.length > 64 || v is! List || v.length != 2 || v.any((e) => e is! num || !e.isFinite || e.abs() > 1000)) {
        throw r.error('pos', 'invalid position for $k');
      }
      pos[k] = ((v[0] as num).toDouble(), (v[1] as num).toDouble());
    });
    final lvl = <String, double>{};
    (r.optMap('lvl') ?? const {}).forEach((k, v) {
      if (k.length > 64 || v is! num || !v.isFinite) throw r.error('lvl', 'invalid level for $k');
      lvl[k] = v.toDouble();
    });
    return SpeakerLayout(
      id: r.integer('id', min: 0),
      listener: r.string('listener', maxLength: 64),
      positions: pos,
      levelsDb: lvl,
      residualM: r.number('res', min: 0, max: 1000),
    );
  }
}

class RoomState {
  final String roomId;
  final String roomName;
  final String coordinatorId;

  /// Incremented when a different device takes over as coordinator.
  final int coordinatorEpoch;

  final int version;
  final PlaybackTimeline timeline;
  final PendingSegment? pending;
  final List<TrackInfo> playlist;
  final double masterVolume;
  final List<ParticipantSummary> participants;
  final DistributionMode distribution;
  final PlaylistRepeat repeat;
  final bool shuffle;

  /// Active acoustic calibration, if any (its click track is not part of the
  /// playlist).
  final CalibrationPlan? calibration;

  /// The device that should be coordinator whenever it is present (the
  /// original host). A successor hands the role back to it (see
  /// `participant/failover.dart`). Null: no preference.
  final String? preferredCoordinator;

  /// Latest "identify this phone" request (see [IdentifyRequest]).
  final IdentifyRequest? identify;

  /// Latest surround calibration result (see [SpeakerLayout]).
  final SpeakerLayout? layout;

  const RoomState({
    required this.roomId,
    required this.roomName,
    required this.coordinatorId,
    this.coordinatorEpoch = 1,
    required this.version,
    required this.timeline,
    this.pending,
    this.playlist = const [],
    this.masterVolume = 1.0,
    this.participants = const [],
    this.distribution = DistributionMode.auto,
    this.repeat = PlaylistRepeat.off,
    this.shuffle = false,
    this.calibration,
    this.preferredCoordinator,
    this.identify,
    this.layout,
  });

  TrackInfo? trackById(String? id) {
    if (id == null) return null;
    for (final t in playlist) {
      if (t.id == id) return t;
    }
    final cal = calibration;
    if (cal != null && cal.trackId == id) {
      return TrackInfo(id: id, title: 'Calibration', durationUs: cal.durationUs, sizeBytes: 0, hostServes: false);
    }
    return null;
  }

  bool isCalibrationTrack(String? id) => id != null && calibration?.trackId == id;

  int indexOfTrack(String? id) => playlist.indexWhere((t) => t.id == id);

  ParticipantSummary? participant(String deviceId) {
    for (final p in participants) {
      if (p.deviceId == deviceId) return p;
    }
    return null;
  }

  RoomState copyWith({
    String? roomName,
    String? coordinatorId,
    int? coordinatorEpoch,
    int? version,
    PlaybackTimeline? timeline,
    PendingSegment? pending,
    bool clearPending = false,
    List<TrackInfo>? playlist,
    double? masterVolume,
    List<ParticipantSummary>? participants,
    DistributionMode? distribution,
    PlaylistRepeat? repeat,
    bool? shuffle,
    CalibrationPlan? calibration,
    bool clearCalibration = false,
    String? preferredCoordinator,
    IdentifyRequest? identify,
    SpeakerLayout? layout,
  }) =>
      RoomState(
        roomId: roomId,
        roomName: roomName ?? this.roomName,
        coordinatorId: coordinatorId ?? this.coordinatorId,
        coordinatorEpoch: coordinatorEpoch ?? this.coordinatorEpoch,
        version: version ?? this.version,
        timeline: timeline ?? this.timeline,
        pending: clearPending ? null : (pending ?? this.pending),
        playlist: playlist ?? this.playlist,
        masterVolume: masterVolume ?? this.masterVolume,
        participants: participants ?? this.participants,
        distribution: distribution ?? this.distribution,
        repeat: repeat ?? this.repeat,
        shuffle: shuffle ?? this.shuffle,
        calibration: clearCalibration ? null : (calibration ?? this.calibration),
        preferredCoordinator: preferredCoordinator ?? this.preferredCoordinator,
        identify: identify ?? this.identify,
        layout: layout ?? this.layout,
      );

  Map<String, Object?> toJson() => {
        'room': roomId,
        'name': roomName,
        'coord': coordinatorId,
        'epoch': coordinatorEpoch,
        'ver': version,
        'tl': timeline.toJson(),
        if (pending != null) 'pending': pending!.toJson(),
        'playlist': [for (final t in playlist) t.toJson()],
        'mvol': masterVolume,
        'parts': [for (final p in participants) p.toJson()],
        'dist': distribution.name,
        if (repeat != PlaylistRepeat.off) 'rep': repeat.name,
        if (shuffle) 'shuf': true,
        if (calibration != null) 'cal': calibration!.toJson(),
        if (preferredCoordinator != null) 'pref': preferredCoordinator,
        if (identify != null) 'ident': identify!.toJson(),
        if (layout != null) 'layout': layout!.toJson(),
      };

  factory RoomState.fromJson(Map<String, Object?> j, {int maxPlaylist = 1000}) {
    final r = Reader(j, 'state');
    return RoomState(
      roomId: r.string('room', maxLength: 64),
      roomName: r.string('name', maxLength: 64),
      coordinatorId: r.string('coord', maxLength: 64),
      coordinatorEpoch: r.integer('epoch', min: 0),
      version: r.integer('ver', min: 0),
      timeline: PlaybackTimeline.fromJson(r.map('tl')),
      pending: r.optMap('pending') == null
          ? null
          : PendingSegment.fromJson(r.optMap('pending')!),
      playlist: [
        for (final m in r.mapList('playlist', maxLength: maxPlaylist))
          TrackInfo.fromJson(m)
      ],
      masterVolume: r.number('mvol', min: 0, max: 1),
      participants: [
        for (final m in r.mapList('parts', maxLength: 256))
          ParticipantSummary.fromJson(m)
      ],
      distribution: r.enumValue('dist', DistributionMode.values),
      repeat: r.optEnum('rep', PlaylistRepeat.values) ?? PlaylistRepeat.off,
      shuffle: r.optBoolean('shuf') ?? false,
      calibration: r.optMap('cal') == null ? null : CalibrationPlan.fromJson(r.optMap('cal')!),
      preferredCoordinator: r.optString('pref', maxLength: 64),
      identify: r.optMap('ident') == null ? null : IdentifyRequest.fromJson(r.optMap('ident')!),
      layout: r.optMap('layout') == null ? null : SpeakerLayout.fromJson(r.optMap('layout')!),
    );
  }
}
