/// Structured, bounded event log shared by coordinator and participants.
/// Every synchronization-relevant decision (clock sample rejected, late
/// command, rate change, resync, reconnect, auth failure, ...) is recorded
/// here with machine-readable data, displayed on the diagnostics screen and
/// exportable as JSON Lines for offline analysis.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import '../time/clock.dart';

enum EventLevel { debug, info, warn, error }

class SyncEvent {
  /// Local monotonic time (µs).
  final int atUs;

  /// Wall-clock time, for humans only.
  final DateTime wallTime;
  final EventLevel level;

  /// Dotted category, e.g. `clock.sample`, `drift.resync`, `member.join`.
  final String category;
  final String message;
  final Map<String, Object?> data;

  SyncEvent({
    required this.atUs,
    required this.wallTime,
    required this.level,
    required this.category,
    required this.message,
    this.data = const {},
  });

  Map<String, Object?> toJson() => {
        'atUs': atUs,
        'wall': wallTime.toIso8601String(),
        'level': level.name,
        'cat': category,
        'msg': message,
        if (data.isNotEmpty) 'data': data,
      };

  @override
  String toString() =>
      '[${(atUs / 1000).toStringAsFixed(1)}ms ${level.name}] $category: $message'
      '${data.isEmpty ? '' : ' $data'}';
}

class EventLog {
  final MonotonicClock clock;
  final int capacity;
  final String source;
  final EventLevel minLevel;
  final Queue<SyncEvent> _events = Queue();
  final StreamController<SyncEvent> _stream = StreamController.broadcast(sync: true);

  /// Optional sink (e.g. stdout in the CLI, `debugPrint` in the app).
  void Function(String source, SyncEvent e)? printer;

  EventLog({
    required this.clock,
    this.capacity = 2000,
    this.source = '',
    this.minLevel = EventLevel.debug,
    this.printer,
  });

  Stream<SyncEvent> get stream => _stream.stream;

  List<SyncEvent> get events => List.unmodifiable(_events);

  List<SyncEvent> recent({int limit = 100, String? categoryPrefix, EventLevel? minLevel}) {
    final out = <SyncEvent>[];
    for (final e in _events.toList().reversed) {
      if (categoryPrefix != null && !e.category.startsWith(categoryPrefix)) continue;
      if (minLevel != null && e.level.index < minLevel.index) continue;
      out.add(e);
      if (out.length >= limit) break;
    }
    return out;
  }

  void add(EventLevel level, String category, String message,
      [Map<String, Object?> data = const {}]) {
    if (level.index < minLevel.index) return;
    final e = SyncEvent(
      atUs: clock.nowMicros(),
      wallTime: DateTime.now(),
      level: level,
      category: category,
      message: message,
      data: data,
    );
    _events.add(e);
    while (_events.length > capacity) {
      _events.removeFirst();
    }
    printer?.call(source, e);
    if (_stream.hasListener) _stream.add(e);
  }

  void debug(String cat, String msg, [Map<String, Object?> data = const {}]) =>
      add(EventLevel.debug, cat, msg, data);
  void info(String cat, String msg, [Map<String, Object?> data = const {}]) =>
      add(EventLevel.info, cat, msg, data);
  void warn(String cat, String msg, [Map<String, Object?> data = const {}]) =>
      add(EventLevel.warn, cat, msg, data);
  void error(String cat, String msg, [Map<String, Object?> data = const {}]) =>
      add(EventLevel.error, cat, msg, data);

  String toJsonLines() => _events.map((e) => jsonEncode(e.toJson())).join('\n');

  Future<void> close() => _stream.close();
}
