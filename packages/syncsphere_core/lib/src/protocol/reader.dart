/// Strict, bounded accessors for untrusted JSON. Every inbound field passes
/// through a [Reader], which enforces type, range and length limits and turns
/// any violation into a [ProtocolException] instead of a runtime type error.
library;

class ProtocolException implements Exception {
  /// Stable machine-readable code (see `docs/protocol.md`).
  final String code;
  final String message;
  const ProtocolException(this.code, this.message);

  @override
  String toString() => 'ProtocolException($code): $message';
}

class Reader {
  final Map<String, Object?> _m;
  final String context;
  Reader(this._m, this.context);

  ProtocolException error(String field, String why) =>
      ProtocolException('malformed', '$context.$field: $why');

  bool has(String k) => _m.containsKey(k) && _m[k] != null;

  String string(String k, {int maxLength = 512, int minLength = 0}) {
    final v = _m[k];
    if (v is! String) throw error(k, 'expected string');
    if (v.length > maxLength) throw error(k, 'longer than $maxLength');
    if (v.length < minLength) throw error(k, 'shorter than $minLength');
    return v;
  }

  String? optString(String k, {int maxLength = 512}) =>
      has(k) ? string(k, maxLength: maxLength) : null;

  int integer(String k, {int? min, int? max}) {
    final v = _m[k];
    if (v is! num || !v.isFinite) throw error(k, 'expected integer');
    if (v is double && v != v.truncateToDouble()) {
      throw error(k, 'expected integer, got fraction');
    }
    final i = v.toInt();
    if (min != null && i < min) throw error(k, 'below $min');
    if (max != null && i > max) throw error(k, 'above $max');
    return i;
  }

  int? optInteger(String k, {int? min, int? max}) =>
      has(k) ? integer(k, min: min, max: max) : null;

  double number(String k, {double? min, double? max}) {
    final v = _m[k];
    if (v is! num || !v.isFinite) throw error(k, 'expected number');
    final d = v.toDouble();
    if (min != null && d < min) throw error(k, 'below $min');
    if (max != null && d > max) throw error(k, 'above $max');
    return d;
  }

  double? optNumber(String k, {double? min, double? max}) =>
      has(k) ? number(k, min: min, max: max) : null;

  bool boolean(String k) {
    final v = _m[k];
    if (v is! bool) throw error(k, 'expected bool');
    return v;
  }

  bool? optBoolean(String k) => has(k) ? boolean(k) : null;

  T enumValue<T extends Enum>(String k, List<T> values) {
    final s = string(k, maxLength: 40);
    for (final v in values) {
      if (v.name == s) return v;
    }
    throw error(k, 'unknown value "$s"');
  }

  T? optEnum<T extends Enum>(String k, List<T> values) =>
      has(k) ? enumValue(k, values) : null;

  Map<String, Object?> map(String k) {
    final v = _m[k];
    if (v is! Map) throw error(k, 'expected object');
    return _castMap(v, k);
  }

  Map<String, Object?>? optMap(String k) => has(k) ? map(k) : null;

  List<Map<String, Object?>> mapList(String k, {int maxLength = 2000}) {
    final v = _m[k];
    if (v is! List) throw error(k, 'expected list');
    if (v.length > maxLength) throw error(k, 'more than $maxLength entries');
    return [
      for (final e in v)
        if (e is Map) _castMap(e, k) else throw error(k, 'expected list of objects')
    ];
  }

  List<String> stringList(String k, {int maxLength = 2000, int maxItemLength = 512}) {
    final v = _m[k];
    if (v is! List) throw error(k, 'expected list');
    if (v.length > maxLength) throw error(k, 'more than $maxLength entries');
    return [
      for (final e in v)
        if (e is String && e.length <= maxItemLength)
          e
        else
          throw error(k, 'expected list of strings ≤ $maxItemLength chars')
    ];
  }

  Map<String, Object?> _castMap(Map<dynamic, dynamic> v, String k) {
    for (final key in v.keys) {
      if (key is! String) throw error(k, 'non-string key');
    }
    return v.cast<String, Object?>();
  }
}
