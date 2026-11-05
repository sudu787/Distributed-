/// Per-phone switches for the riskier parts of the sync engines, so a
/// problem found on real phones can be turned off (or bisected) without a
/// new build. Stored by the app; unknown or malformed values fall back to
/// the defaults.
library;

class FeatureFlags {
  /// Warm start: keep the audio output awake between songs.
  final bool keepAwake;

  /// Warm start: measure the start delay with a silent test start while the
  /// room is idle.
  final bool startProbe;

  /// Precise engine: fall back to Classic on this phone when the renderer
  /// fails (otherwise report the error and stay silent).
  final bool preciseFallback;

  /// Experimental left/right/mono channel roles.
  final bool channelRoles;

  const FeatureFlags({
    this.keepAwake = true,
    this.startProbe = true,
    this.preciseFallback = true,
    this.channelRoles = true,
  });

  FeatureFlags copyWith({bool? keepAwake, bool? startProbe, bool? preciseFallback, bool? channelRoles}) =>
      FeatureFlags(
        keepAwake: keepAwake ?? this.keepAwake,
        startProbe: startProbe ?? this.startProbe,
        preciseFallback: preciseFallback ?? this.preciseFallback,
        channelRoles: channelRoles ?? this.channelRoles,
      );

  Map<String, Object?> toJson() => {
        'keepAwake': keepAwake,
        'startProbe': startProbe,
        'preciseFallback': preciseFallback,
        'channelRoles': channelRoles,
      };

  factory FeatureFlags.fromJson(Object? json) {
    const d = FeatureFlags();
    if (json is! Map) return d;
    bool flag(String k, bool def) => json[k] is bool ? json[k] as bool : def;
    return FeatureFlags(
      keepAwake: flag('keepAwake', d.keepAwake),
      startProbe: flag('startProbe', d.startProbe),
      preciseFallback: flag('preciseFallback', d.preciseFallback),
      channelRoles: flag('channelRoles', d.channelRoles),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FeatureFlags &&
      other.keepAwake == keepAwake &&
      other.startProbe == startProbe &&
      other.preciseFallback == preciseFallback &&
      other.channelRoles == channelRoles;

  @override
  int get hashCode => Object.hash(keepAwake, startProbe, preciseFallback, channelRoles);
}
