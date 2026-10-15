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
library;

import 'dart:async';
import 'dart:math';

import '../audio/audio_backend.dart';
import '../model/room_state.dart' show ChannelRole;
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
      };

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
  AudioCapabilities get capabilities => AudioCapabilities(
        backend: 'simulated-${profile.name}',
        rateControl: profile.rateControl,
        minRate: profile.rateControl ? 0.5 : 1.0,
        maxRate: profile.rateControl ? 2.0 : 1.0,
        outputLatencyHintUs: _latencyHintUs,
      );

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
  }

  @override
  Future<void> startAt({required int segmentId, required int atLocalUs}) async {
    final jitter = profile.scheduleJitterUs <= 0 ? 0 : _rnd.nextInt(profile.scheduleJitterUs + 1);
    Timer(_untilLocal(atLocalUs) + Duration(microseconds: jitter), () => _playCall(segmentId));
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
    final latency = max(1000, profile.startLatencyMeanUs + _uniform(profile.startLatencyJitterUs));
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
      _outputting = false;
      _events.add(AudioBackendEvent(AudioEventKind.paused, segmentId, localClock.nowMicros()));
    });
  }

  @override
  Future<void> setRate(double rate) async {
    if (!profile.rateControl) return;
    rateChanges++;
    Timer(Duration(microseconds: profile.rateChangeLatencyUs), () {
      _rate = rate;
      if (_outputting && !_stalled) _reanchor(trueNowUs(), _rate * _audioFactor);
    });
  }

  @override
  Future<void> setVolume(double volume) async {}

  ChannelRole channelRole = ChannelRole.stereo;

  @override
  Future<void> setChannelRole(ChannelRole role) async => channelRole = role;

  @override
  Future<void> stop() async {
    _outputting = false;
    _activeId = null;
    _standby = null;
  }

  @override
  Future<PositionSample?> samplePosition() async {
    final id = _activeId;
    if (id == null) return null;
    final t = trueNowUs();
    final noise = (_gauss() * profile.positionNoiseUs).round();
    final reported = _posAt(t) + profile.positionBiasUs + noise;
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
