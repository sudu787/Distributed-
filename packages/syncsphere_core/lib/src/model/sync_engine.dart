/// The room-wide choice of how phones start and track playback.
///
/// The coordinator owns the choice ([RoomState.engine]); every phone follows
/// it. `classic` is the behaviour of the October 18 build and is always the
/// safe fallback: an unknown value (from a newer build) reads as `classic`,
/// and a phone whose engine fails falls back to it.
library;

enum SyncEngineMode {
  /// ExoPlayer; the play call is issued early by a learned start latency.
  classic,

  /// Like [classic], but the audio output is kept awake between songs and the
  /// start latency is measured with a silent test start while idle.
  warm,

  /// Own PCM renderer: the first sample is placed at the target output frame
  /// and positions come from the speaker's frame timestamps.
  precise;

  /// Parses a wire value; anything unknown is [classic].
  static SyncEngineMode parse(Object? value) {
    for (final m in values) {
      if (m.name == value) return m;
    }
    return classic;
  }

  String get label => switch (this) {
        classic => 'Classic',
        warm => 'Warm start',
        precise => 'Precise',
      };

  String get description => switch (this) {
        classic => 'The original engine (October 18 build). Safe fallback.',
        warm => 'Keeps the speaker awake and measures each phone\'s start delay in advance.',
        precise => 'Starts every phone on the exact audio frame and measures at the speaker.',
      };
}
