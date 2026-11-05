/// Guards the sync core's boundary (docs/sync-core.md): the code that
/// decides *when* audio plays may not depend on feature modules. Features
/// use the core through its interfaces; they never reach inside it, and the
/// core never imports them. A failure here means a feature crept into the
/// sync path, which is how the October regression happened.
library;

import 'dart:io';

import 'package:test/test.dart';

/// The sync core, relative to lib/src.
const _core = [
  'time/',
  'audio/',
  'config/',
  'participant/playback_engine.dart',
  'participant/drift_controller.dart',
  'participant/start_policy.dart',
  'participant/start_probe.dart',
  'participant/start_stats.dart',
  'participant/clock_prober.dart',
];

/// What the core may import besides itself: data models, the wire
/// protocol, logging and stats helpers.
const _shared = ['model/', 'protocol/', 'observability/', 'util/'];

/// Interfaces the playback engine needs from features (and only these).
const _allowed = {
  'participant/playback_engine.dart': {
    'distribution/track_resolver.dart', // where track files come from
    'calibration/calibration_runtime.dart', // click tracks for calibration
  },
};

bool _inCore(String path) => _core.any((c) => c.endsWith('/') ? path.startsWith(c) : path == c);

/// lib/src-relative targets of a file's relative imports and exports.
List<String> _deps(File f, String src) {
  final dir = File(f.path).parent.path;
  final out = <String>[];
  for (final m in RegExp(r'''^(?:import|export)\s+'([^':]+)'(?:\s|;)''', multiLine: true).allMatches(f.readAsStringSync())) {
    final target = File('$dir/${m.group(1)}').absolute.uri.normalizePath().toFilePath();
    if (target.startsWith(src)) out.add(target.substring(src.length));
  }
  return out;
}

void main() {
  final src = Directory('lib/src').absolute.uri.normalizePath().toFilePath();
  final files = Directory(src).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));

  test('the sync core imports only itself, shared models/protocol, and its declared interfaces', () {
    final violations = <String>[];
    for (final f in files) {
      final path = f.absolute.uri.normalizePath().toFilePath().substring(src.length);
      if (!_inCore(path)) continue;
      for (final dep in _deps(f, src)) {
        if (_inCore(dep) || _shared.any(dep.startsWith) || (_allowed[path]?.contains(dep) ?? false)) continue;
        violations.add('$path → $dep');
      }
    }
    expect(violations, isEmpty, reason: 'feature modules leaked into the sync core');
  });

  test('the boundary list names real files', () {
    for (final c in _core) {
      final e = c.endsWith('/') ? Directory('$src$c').existsSync() : File('$src$c').existsSync();
      expect(e, isTrue, reason: '$c in the sync-core list does not exist');
    }
  });

  test('shared models do not depend on features either', () {
    final violations = <String>[];
    for (final f in files) {
      final path = f.absolute.uri.normalizePath().toFilePath().substring(src.length);
      if (!path.startsWith('model/')) continue;
      for (final dep in _deps(f, src)) {
        if (dep.startsWith('model/') || dep.startsWith('protocol/')) continue;
        violations.add('$path → $dep');
      }
    }
    expect(violations, isEmpty);
  });
}
