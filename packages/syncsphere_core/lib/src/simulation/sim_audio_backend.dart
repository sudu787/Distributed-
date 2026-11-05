/// Simulated audio output device with *ground truth*.
///
/// Models the parts of a real phone's audio path that matter for
/// synchronization: native scheduling jitter, a variable delay between the
/// play call and audible output, an audio clock that runs slightly fast or
/// slow, noisy and possibly biased position reports, delayed rate changes,
/// prepare time and random buffering stalls.
///
/// The simulator can query the *acoustic* position (what actually leaves
/// the speaker) independently of what the backend reports, which is what
/// makes it possible to quantify the gap between software-estimated and
/// true alignment. Nothing produced by this class is a hardware measurement.
///
/// ## Phone-like behaviour (optional, off in the original profiles)
/// * **Cold start:** an output that has been silent for [DeviceAudioProfile
///   .standbyAfterUs] is in standby; the next start takes extra time
///   ([coldStartExtraMeanUs] ± [coldStartExtraJitterUs]).
/// * **Report smoothing:** right after a start the reported position is off
///   by up to ±[earlyReportErrorUs], decaying to zero over [reportSettleUs]
///   (ExoPlayer's head-position estimate and its smoothing).
///
/// ## Engines
/// `classic` and `warm` model ExoPlayer (warm keeps the output awake while
/// the room uses it); `precise` models the own renderer: the start time is
/// the audible time (± [preciseStartErrorUs]), a late start skips content to
/// stay aligned, and reports are timestamp-exact (± [timestampNoiseUs]).
library;

import 'dart:async';
import 'dart:math';

import '../audio/audio_backend.dart';
import '../config/feature_flags.dart';
import '../model/room_state.dart' show ChannelRole;
import '../model/sync_engine.dart';
import '../time/clock.dart';

class DeviceAudioProfile {
  final String name;

  /// Play call → first audible frame.
  final int startLatencyMeanUs;
  final int startLatencyJitterUs;

  /// Native timer accuracy: the play call fires up to this late.
  final int scheduleJitterUs;

  /// Audio clock frequency error (ppm) relative to true time.
  final double audioClockPpm;

  /// Standard deviation of position-report noise.
  final int positionNoiseUs;

  /// Reported minus acoustic position (e.g. unreported Bluetooth latency).
  final int positionBiasUs;

  /// Delay until a rate change affects audible output (buffered audio).
  final int rateChangeLatencyUs;
  final int prepareMeanUs;
  final int prepareJitterUs;
  final double stallsPerHour;
  final int stallDurationUs;
  final bool rateControl;

  /// Silence after which the output enters standby (0: never).
  final int standbyAfterUs;

  /// Extra start latency when the output was in standby.
  final int coldStartExtraMeanUs;
  final int coldStartExtraJitterUs;

  /// Reported-position error right after a start, and how long it takes to
  /// decay (ExoPlayer smoothing).
  final int earlyReportErrorUs;
  final int reportSettleUs;

  /// Precise renderer: start placement error and timestamp noise.
  final int preciseStartErrorUs;
  final int timestampNoiseUs;

  const DeviceAudioProfile({
    required this.name,
    this.startLatencyMeanUs = 60000,
    this.startLatencyJitterUs = 10000,
    this.scheduleJitterUs = 2000,
    this.audioClockPpm = 0,
    this.positionNoiseUs = 1500,
    this.positionBiasUs = 0,
    this.rateChangeLatencyUs = 150000,
    this.prepareMeanUs = 250000,
    this.prepareJitterUs = 100000,
    this.stallsPerHour = 0,
    this.stallDurationUs = 300000,
    this.rateControl = true,
    this.standbyAfterUs = 0,
    this.coldStartExtraMeanUs = 0,
    this.coldStartExtraJitterUs = 0,
    this.earlyReportErrorUs = 0,
    this.reportSettleUs = 2000000,
    this.preciseStartErrorUs = 500,
    this.timestampNoiseUs = 300,
  });

  DeviceAudioProfile withClockPpm(double ppm) => DeviceAudioProfile(
        name: name,
        startLatencyMeanUs: startLatencyMeanUs,
        startLatencyJitterUs: startLatencyJitterUs,
        scheduleJitterUs: scheduleJitterUs,
        audioClockPpm: ppm,
        positionNoiseUs: positionNoiseUs,
        positionBiasUs: positionBiasUs,
        rateChangeLatencyUs: rateChangeLatencyUs,
        prepareMeanUs: prepareMeanUs,
        prepareJitterUs: prepareJitterUs,
        stallsPerHour: stallsPerHour,
        stallDurationUs: stallDurationUs,
        rateControl: rateControl,
        standbyAfterUs: standbyAfterUs,
        coldStartExtraMeanUs: coldStartExtraMeanUs,
        coldStartExtraJitterUs: coldStartExtraJitterUs,
        earlyReportErrorUs: earlyReportErrorUs,
        reportSettleUs: reportSettleUs,
        preciseStartErrorUs: preciseStartErrorUs,
        timestampNoiseUs: timestampNoiseUs,
      );

  Map<String, Object?> toJson() => {
        'name': name,
        'startLatencyMeanUs': startLatencyMeanUs,
        'startLatencyJitterUs': startLatencyJitterUs,
        'scheduleJitterUs': scheduleJitterUs,
        'audioClockPpm': audioClockPpm,
        'positionNoiseUs': positionNoiseUs,
        'positionBiasUs': positionBiasUs,
        'rateChangeLatencyUs': rateChangeLatencyUs,
        'prepareMeanUs': prepareMeanUs,
        'stallsPerHour': stallsPerHour,
        'rateControl': rateControl,
        if (standbyAfterUs > 0) 'standbyAfterUs': standbyAfterUs,
        if (coldStartExtraMeanUs > 0) 'coldStartExtraMeanUs': coldStartExtraMeanUs,
        if (coldStartExtraJitterUs > 0) 'coldStartExtraJitterUs': coldStartExtraJitterUs,
        if (earlyReportErrorUs > 0) 'earlyReportErrorUs': earlyReportErrorUs,
        if (earlyReportErrorUs > 0) 'reportSettleUs': reportSettleUs,
        if (preciseStartErrorUs != 500) 'preciseStartErrorUs': preciseStartErrorUs,
        if (timestampNoiseUs != 300) 'timestampNoiseUs': timestampNoiseUs,
      };

  /// Reads a profile (e.g. one exported from a real phone); missing fields
  /// take the [DeviceAudioProfile] defaults, out-of-range values are clamped.
  factory DeviceAudioProfile.fromJson(Map<String, Object?> j) {
    const d = DeviceAudioProfile(name: '');
    int i(String k, int def, [int lo = 0, int hi = 10000000]) {
      final v = j[k];
      return v is num && v.isFinite ? v.toInt().clamp(lo, hi) : def;
    }

    double f(String k, double def, double lo, double hi) {
      final v = j[k];
      return v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : def;
    }

    return DeviceAudioProfile(
      name: j['name'] is String ? j['name'] as String : 'phone',
      startLatencyMeanUs: i('startLatencyMeanUs', d.startLatencyMeanUs, 1000, 2000000),
      startLatencyJitterUs: i('startLatencyJitterUs', d.startLatencyJitterUs),
      scheduleJitterUs: i('scheduleJitterUs', d.scheduleJitterUs),
      audioClockPpm: f('audioClockPpm', d.audioClockPpm, -1000, 1000),
      positionNoiseUs: i('positionNoiseUs', d.positionNoiseUs),
      positionBiasUs: i('positionBiasUs', d.positionBiasUs, -2000000, 2000000),
      rateChangeLatencyUs: i('rateChangeLatencyUs', d.rateChangeLatencyUs),
      prepareMeanUs: i('prepareMeanUs', d.prepareMeanUs, 1000),
      prepareJitterUs: i('prepareJitterUs', d.prepareJitterUs),
      stallsPerHour: f('stallsPerHour', d.stallsPerHour, 0, 3600),
      rateControl: j['rateControl'] is bool ? j['rateControl'] as bool : d.rateControl,
      standbyAfterUs: i('standbyAfterUs', d.standbyAfterUs),
      coldStartExtraMeanUs: i('coldStartExtraMeanUs', d.coldStartExtraMeanUs),
      coldStartExtraJitterUs: i('coldStartExtraJitterUs', d.coldStartExtraJitterUs),
      earlyReportErrorUs: i('earlyReportErrorUs', d.earlyReportErrorUs),
      reportSettleUs: i('reportSettleUs', d.reportSettleUs, 1),
      preciseStartErrorUs: i('preciseStartErrorUs', d.preciseStartErrorUs),
      timestampNoiseUs: i('timestampNoiseUs', d.timestampNoiseUs),
    );
  }

  /// Modelled device classes. Values are plausible assumptions drawn from
  /// public Android audio-latency discussions, *not* measurements; replace
  /// them with real-device numbers from the benchmark procedure.
  static const flagship = DeviceAudioProfile(
      name: 'flagship', startLatencyMeanUs: 45000, startLatencyJitterUs: 6000, scheduleJitterUs: 1000, positionNoiseUs: 800);
  static const midrange = DeviceAudioProfile(
      name: 'midrange', startLatencyMeanUs: 80000, startLatencyJitterUs: 15000, scheduleJitterUs: 2500, positionNoiseUs: 1500);
  static const lowEnd = DeviceAudioProfile(
      name: 'low-end',
      startLatencyMeanUs: 140000,
      startLatencyJitterUs: 35000,
      scheduleJitterUs: 6000,
      positionNoiseUs: 4000,
      prepareMeanUs: 600000,
      stallsPerHour: 6,
      rateControl: false);
  static const bluetoothUncalibrated = DeviceAudioProfile(
      name: 'bluetooth-uncalibrated',
      startLatencyMeanUs: 90000,
      startLatencyJitterUs: 20000,
      positionBiasUs: 180000,
      positionNoiseUs: 3000);

  /// Phone-like variants: output standby after 3 s of silence with a slow,
  /// variable wake-up, and ExoPlayer's smoothed position right after a
  /// start. Modelled assumptions (consistent with the real-phone report of
  /// an echo at the start), *not* measurements; replace them with profiles
  /// exported from phones (Diagnostics → Export phone profile).
  static const phoneFlagship = DeviceAudioProfile(
      name: 'phone-flagship',
      startLatencyMeanUs: 45000,
      startLatencyJitterUs: 6000,
      scheduleJitterUs: 1000,
      positionNoiseUs: 800,
      standbyAfterUs: 3000000,
      coldStartExtraMeanUs: 70000,
      coldStartExtraJitterUs: 40000,
      earlyReportErrorUs: 25000);
  static const phoneMidrange = DeviceAudioProfile(
      name: 'phone-midrange',
      startLatencyMeanUs: 80000,
      startLatencyJitterUs: 15000,
      scheduleJitterUs: 2500,
      positionNoiseUs: 1500,
      standbyAfterUs: 3000000,
      coldStartExtraMeanUs: 110000,
      coldStartExtraJitterUs: 60000,
      earlyReportErrorUs: 40000,
      preciseStartErrorUs: 1000,
      timestampNoiseUs: 500);
  static const phoneLowEnd = DeviceAudioProfile(
      name: 'phone-low-end',
      startLatencyMeanUs: 140000,
      startLatencyJitterUs: 35000,
      scheduleJitterUs: 6000,
      positionNoiseUs: 4000,
      prepareMeanUs: 600000,
      rateControl: false,
      standbyAfterUs: 3000000,
      coldStartExtraMeanUs: 160000,
      coldStartExtraJitterUs: 90000,
      earlyReportErrorUs: 60000,
      preciseStartErrorUs: 2000,
      timestampNoiseUs: 1000);
}

class _Standby {
  final int id;
  final int positionUs;
  _Standby(this.id, this.positionUs);
}

class SimulatedAudioBackend implements AudioBackend {
  final DeviceAudioProfile profile;

  /// True (reference) time in µs.
  final int Function() trueNowUs;

  /// This device's local monotonic clock (what the engine uses).
  final DerivedClock localClock;
  final Random _rnd;
  final StreamController<AudioBackendEvent> _events = StreamController.broadcast(sync: true);

  _Standby? _standby;
  int? _activeId;
  bool _outputting = false;
  bool _stalled = false;
  int _anchorTrue = 0;
  int _anchorPos = 0;
  double _slope = 1.0;
  double _rate = 1.0;
  int _frozenPos = 0;
  Timer? _stallTimer;
  bool _disposed = false;

  SyncEngineMode _engine = SyncEngineMode.classic;

  /// True time the output last went silent (null: never played, i.e. cold).
  int? _silentSinceTrue;

  /// Warm engine with keep-awake: the output never enters standby.
  bool _keptAwake = false;

  /// Report-smoothing error of the current start: initial value and when it
  /// started decaying.
  int _earlyErrUs = 0;
  int _earlyFromTrue = 0;

  /// Ground truth: how many starts found the output in standby.
  int coldStarts = 0;

  /// Ground-truth record of every output start: (segmentId, trueTime, pos).
  final List<(int, int, int)> outputStarts = [];
  int stallCount = 0;
  int rateChanges = 0;
  int playCalls = 0;

  SimulatedAudioBackend({
    required this.profile,
    required this.trueNowUs,
    required this.localClock,
    Random? random,
  }) : _rnd = random ?? Random() {
    if (profile.stallsPerHour > 0) {
      _stallTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _maybeStall());
    }
  }

  /// Platform latency estimate with ±30 % error, like `AudioTrack` /
  /// `AudioManager` hints on real devices (which ignore e.g. Bluetooth).
  late final int _latencyHintUs =
      (profile.startLatencyMeanUs * (0.7 + 0.6 * _rnd.nextDouble())).round();

  @override
  AudioCapabilities get capabilities => _engine == SyncEngineMode.precise
      ? AudioCapabilities(
          backend: 'simulated-precise-${profile.name}',
          rateControl: true,
          minRate: 0.9,
          maxRate: 1.1,
          schedulesOutput: true,
        )
      : AudioCapabilities(
          backend: 'simulated-${profile.name}',
          rateControl: profile.rateControl,
          minRate: profile.rateControl ? 0.5 : 1.0,
          maxRate: profile.rateControl ? 2.0 : 1.0,
          outputLatencyHintUs: _latencyHintUs,
        );

  @override
  Set<SyncEngineMode> get supportedEngines => SyncEngineMode.values.toSet();

  SyncEngineMode get engine => _engine;

  @override
  Future<SyncEngineMode> useEngine(SyncEngineMode mode, FeatureFlags flags) async {
    await stop();
    _engine = mode;
    _keptAwake = mode == SyncEngineMode.warm && flags.keepAwake;
    return mode;
  }

  /// Makes the selected engine fail like a broken renderer would: the
  /// backend drops everything, runs Classic and says so.
  void failEngine(String why) {
    if (_engine == SyncEngineMode.classic) return;
    _outputting = false;
    _activeId = null;
    _standby = null;
    _engine = SyncEngineMode.classic;
    _keptAwake = false;
    _events.add(AudioBackendEvent(AudioEventKind.engineFallback, -1, localClock.nowMicros(), why));
  }

  bool _outputCold(int now) {
    if (profile.standbyAfterUs <= 0 || _outputting) return false;
    if (_engine == SyncEngineMode.precise) return false; // its track never stops while in use
    if (_keptAwake) return false;
    final since = _silentSinceTrue;
    return since == null || now - since >= profile.standbyAfterUs;
  }

  void _wentSilent() {
    if (_outputting) _silentSinceTrue = trueNowUs();
  }

  double get _audioFactor => 1 + profile.audioClockPpm / 1e6;

  /// Acoustic position at true time [t], or null if nothing is audible.
  int? acousticPositionAt(int t) {
    if (!_outputting || _stalled || t < _anchorTrue) return null;
    return _anchorPos + ((t - _anchorTrue) * _slope).round();
  }

  int? get activeSegment => _activeId;

  int _posAt(int t) {
    if (!_outputting) return _frozenPos;
    if (t < _anchorTrue) return _anchorPos;
    return _anchorPos + ((t - _anchorTrue) * _slope).round();
  }

  void _reanchor(int t, double slope) {
    final p = _posAt(t);
    _anchorPos = p;
    _anchorTrue = max(t, _anchorTrue);
    _slope = slope;
  }

  int _uniform(int halfWidth) => halfWidth <= 0 ? 0 : _rnd.nextInt(2 * halfWidth + 1) - halfWidth;

  double _gauss() {
    final u1 = 1.0 - _rnd.nextDouble(), u2 = _rnd.nextDouble();
    return sqrt(-2 * log(u1)) * cos(2 * pi * u2);
  }

  Duration _untilLocal(int atLocalUs) {
    final trueAt = localClock.toReference(atLocalUs);
    final d = trueAt - trueNowUs();
    return Duration(microseconds: d < 0 ? 0 : d);
  }

  @override
  Future<void> prepare({required int segmentId, required TrackSource source, required int positionUs}) async {
    final d = profile.prepareMeanUs + _uniform(profile.prepareJitterUs);
    await Future<void>.delayed(Duration(microseconds: max(1000, d)));
    if (_disposed) throw const AudioBackendException('disposed', 'backend disposed');
    _standby = _Standby(segmentId, positionUs);
    // Like the Media3 backend, the role is fixed when a segment is prepared.
    _segmentRoles[segmentId] = channelRole;
  }

  @override
  Future<void> startAt({required int segmentId, required int atLocalUs}) async {
    if (_engine == SyncEngineMode.precise) {
      _scheduleOutputStart(segmentId, atLocalUs);
      return;
    }
    final jitter = profile.scheduleJitterUs <= 0 ? 0 : _rnd.nextInt(profile.scheduleJitterUs + 1);
    Timer(_untilLocal(atLocalUs) + Duration(microseconds: jitter), () => _playCall(segmentId));
  }

  /// Precise renderer: [atLocalUs] is the audible time of the segment's
  /// first frame. The writer renders ~20 ms ahead; a start that is already
  /// due when it is processed begins at once, skipping the content that
  /// should have played meanwhile (so it is still aligned).
  void _scheduleOutputStart(int segmentId, int atLocalUs) {
    final targetTrue = localClock.toReference(atLocalUs) + _uniform(profile.preciseStartErrorUs);
    final processAt = max(trueNowUs(), targetTrue - 20000);
    Timer(Duration(microseconds: processAt - trueNowUs()), () {
      if (_disposed) return;
      final sb = _standby;
      int startPos;
      if (sb != null && sb.id == segmentId) {
        startPos = sb.positionUs;
        _standby = null;
      } else if (_activeId == segmentId && !_outputting) {
        startPos = _frozenPos;
      } else {
        _events.add(AudioBackendEvent(AudioEventKind.error, segmentId, localClock.nowMicros(), 'segment $segmentId not prepared'));
        return;
      }
      playCalls++;
      final now = trueNowUs();
      final at = max(now + 20000, targetTrue);
      _activeId = segmentId;
      _outputting = true;
      _stalled = false;
      _anchorTrue = at;
      _anchorPos = startPos + ((at - targetTrue) * _rate).round();
      _slope = _rate * _audioFactor;
      _earlyErrUs = 0;
      outputStarts.add((segmentId, _anchorTrue, _anchorPos));
      _events.add(AudioBackendEvent(AudioEventKind.playCalled, segmentId, localClock.nowMicros()));
    });
  }

  void _playCall(int segmentId) {
    if (_disposed) return;
    final now = trueNowUs();
    int startPos;
    final sb = _standby;
    if (sb != null && sb.id == segmentId) {
      startPos = sb.positionUs;
      _standby = null;
    } else if (_activeId == segmentId && !_outputting) {
      startPos = _frozenPos;
    } else {
      _events.add(AudioBackendEvent(AudioEventKind.error, segmentId, localClock.nowMicros(), 'segment $segmentId not prepared'));
      return;
    }
    playCalls++;
    var latency = max(1000, profile.startLatencyMeanUs + _uniform(profile.startLatencyJitterUs));
    if (_outputCold(now)) {
      coldStarts++;
      latency += max(0, profile.coldStartExtraMeanUs + _uniform(profile.coldStartExtraJitterUs));
    }
    if (profile.earlyReportErrorUs > 0) {
      _earlyErrUs = _uniform(profile.earlyReportErrorUs);
      _earlyFromTrue = now + latency;
    }
    _activeId = segmentId;
    _outputting = true;
    _stalled = false;
    _anchorTrue = now + latency;
    _anchorPos = startPos;
    _slope = _rate * _audioFactor;
    outputStarts.add((segmentId, _anchorTrue, startPos));
    _events.add(AudioBackendEvent(AudioEventKind.playCalled, segmentId, localClock.nowMicros()));
  }

  @override
  Future<void> pauseAt({required int segmentId, required int atLocalUs, int? thenSeekToUs}) async {
    Timer(_untilLocal(atLocalUs), () {
      if (_disposed || _activeId != segmentId || !_outputting) return;
      _frozenPos = thenSeekToUs ?? _posAt(trueNowUs());
      _wentSilent();
      _outputting = false;
      _events.add(AudioBackendEvent(AudioEventKind.paused, segmentId, localClock.nowMicros()));
    });
  }

  @override
  Future<void> setRate(double rate) async {
    final precise = _engine == SyncEngineMode.precise;
    if (!profile.rateControl && !precise) return;
    rateChanges++;
    // The renderer applies a rate at its write-ahead (~20 ms); ExoPlayer
    // after its buffered audio.
    Timer(Duration(microseconds: precise ? 20000 : profile.rateChangeLatencyUs), () {
      _rate = rate;
      if (_outputting && !_stalled) _reanchor(trueNowUs(), _rate * _audioFactor);
    });
  }

  @override
  Future<void> setVolume(double volume) async {}

  ChannelRole channelRole = ChannelRole.stereo;
  final Map<int, ChannelRole> _segmentRoles = {};

  /// Channel role of the segment currently rendering (null when silent).
  ChannelRole? get activeRole => _activeId == null ? null : _segmentRoles[_activeId];

  @override
  Future<void> setChannelRole(ChannelRole role) async => channelRole = role;

  @override
  Future<void> stop() async {
    _wentSilent();
    _outputting = false;
    _activeId = null;
    _standby = null;
  }

  @override
  Future<PositionSample?> samplePosition() async {
    final id = _activeId;
    if (id == null) return null;
    final t = trueNowUs();
    final precise = _engine == SyncEngineMode.precise;
    final noise = (_gauss() * (precise ? profile.timestampNoiseUs : profile.positionNoiseUs)).round();
    var reported = _posAt(t) + profile.positionBiasUs + noise;
    if (!precise && _earlyErrUs != 0 && _outputting && t >= _earlyFromTrue) {
      final left = 1 - (t - _earlyFromTrue) / profile.reportSettleUs;
      if (left > 0) reported += (_earlyErrUs * left).round();
    }
    return PositionSample(
      segmentId: id,
      positionUs: reported,
      atLocalUs: localClock.nowMicros(),
      playing: _outputting,
      bufferedUs: 5000000,
      rate: _rate,
      state: _stalled ? 'buffering' : (_outputting ? 'ready' : 'paused'),
      fromAudioTimestamp: true,
    );
  }

  void _maybeStall() {
    if (!_outputting || _stalled) return;
    final p = profile.stallsPerHour / 36000; // per 100 ms
    if (_rnd.nextDouble() >= p) return;
    final t = trueNowUs();
    if (t < _anchorTrue) return;
    _reanchor(t, 0);
    _stalled = true;
    stallCount++;
    _events.add(AudioBackendEvent(AudioEventKind.stalled, _activeId ?? -1, localClock.nowMicros()));
    Timer(Duration(microseconds: profile.stallDurationUs), () {
      if (!_stalled) return;
      _stalled = false;
      _reanchor(trueNowUs(), _rate * _audioFactor);
      _events.add(AudioBackendEvent(AudioEventKind.resumedAfterStall, _activeId ?? -1, localClock.nowMicros()));
    });
  }

  @override
  Stream<AudioBackendEvent> get events => _events.stream;

  @override
  Future<void> dispose() async {
    _disposed = true;
    _stallTimer?.cancel();
    await _events.close();
  }
}
