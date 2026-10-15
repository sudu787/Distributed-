/// Small statistics helpers used by diagnostics and the benchmark harness.
library;

import 'dart:math' as math;

/// Exact percentiles over a stored sample (benchmark sizes are small enough).
class SampleStats {
  final List<double> _values = [];

  void add(num v) => _values.add(v.toDouble());
  void addAll(Iterable<num> vs) => vs.forEach(add);

  int get count => _values.length;
  bool get isEmpty => _values.isEmpty;

  List<double> get sorted => List.of(_values)..sort();

  double percentile(double p) {
    if (_values.isEmpty) return double.nan;
    final s = sorted;
    if (s.length == 1) return s.first;
    final rank = p * (s.length - 1);
    final lo = rank.floor(), hi = rank.ceil();
    return s[lo] + (s[hi] - s[lo]) * (rank - lo);
  }

  double get median => percentile(0.5);
  double get p95 => percentile(0.95);
  double get p99 => percentile(0.99);
  double get max => _values.isEmpty ? double.nan : _values.reduce(math.max);
  double get min => _values.isEmpty ? double.nan : _values.reduce(math.min);
  double get mean =>
      _values.isEmpty ? double.nan : _values.reduce((a, b) => a + b) / _values.length;

  double get stddev {
    if (_values.length < 2) return 0;
    final m = mean;
    var acc = 0.0;
    for (final v in _values) {
      acc += (v - m) * (v - m);
    }
    return math.sqrt(acc / (_values.length - 1));
  }

  Map<String, Object?> summary({int decimals = 2}) {
    if (_values.isEmpty) return const {'n': 0};
    double r(double v) => double.parse(v.toStringAsFixed(decimals));
    return {
      'n': count,
      'median': r(median),
      'p95': r(p95),
      'p99': r(p99),
      'max': r(max),
      'mean': r(mean),
    };
  }
}

/// Fixed-size sliding window with median, used for noise-robust filtering.
class SlidingWindow {
  final int capacity;
  final List<double> _v = [];
  SlidingWindow(this.capacity);

  void add(double x) {
    _v.add(x);
    if (_v.length > capacity) _v.removeAt(0);
  }

  void clear() => _v.clear();
  int get length => _v.length;
  bool get isFull => _v.length >= capacity;

  double get median {
    if (_v.isEmpty) return double.nan;
    final s = List.of(_v)..sort();
    final n = s.length;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
  }

  double get last => _v.isEmpty ? double.nan : _v.last;
}
