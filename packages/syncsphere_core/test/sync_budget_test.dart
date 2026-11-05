/// The sync regression gate (docs/sync-core.md): fixed-seed simulations of
/// phone-like devices that every change must keep within budget. Classic
/// itself is pinned exactly by classic_golden_test.dart. All numbers are
/// SIMULATED; the budgets leave headroom over today's results so only real
/// regressions fail.
library;

import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

const _controls = [
  ScheduledAction(Duration(seconds: 3), PlayAction()),
  ScheduledAction(Duration(seconds: 30), PauseAction()),
  ScheduledAction(Duration(seconds: 38), PlayAction()),
  ScheduledAction(Duration(seconds: 60), SeekAction(Duration(minutes: 2))),
  ScheduledAction(Duration(seconds: 80), NextTrackAction()),
];

/// p95 budgets (ms): spread in the first 3 s after each start, and after.
/// Worst cases over 80 seeded runs (Nov 2026): warm 84 / 54, precise 4 / 6;
/// warm is limited by the modelled low-end phone's ±35 ms start variance.
const _budgets = {
  SyncEngineMode.warm: (first3s: 100.0, steady: 65.0),
  SyncEngineMode.precise: (first3s: 8.0, steady: 8.0),
};

SimulationResult _run(SyncEngineMode engine, NetworkCondition net, int n, int seed) => SimulationRunner(Scenario(
      name: 'budget-${engine.name}-${net.name}-n$n',
      participants: n,
      network: net,
      duration: const Duration(seconds: 110),
      profiles: const [DeviceAudioProfile.phoneFlagship, DeviceAudioProfile.phoneMidrange, DeviceAudioProfile.phoneLowEnd],
      engine: engine,
      actions: _controls,
      seed: seed,
    )).run();

double _p95(SimulationResult r, String key) => ((r.metrics[key] as Map)['p95'] as num).toDouble();

void main() {
  for (final net in [NetworkCondition.wifiGood, NetworkCondition.wifiTypical]) {
    for (final n in [3, 5]) {
      test('engines stay within budget: ${net.name}, $n phones (SIMULATED)', () {
        final results = {for (final e in SyncEngineMode.values) e: _run(e, net, n, 40 + n)};
        for (final e in _budgets.keys) {
          final r = results[e]!;
          expect(r.metrics['failedSessions'], isEmpty, reason: '${e.name}: sessions failed');
          expect(r.metrics['engines'], everyElement(e.name), reason: '${e.name}: a phone left the engine');
          expect(_p95(r, 'interDeviceSpreadMs_first3s'), lessThanOrEqualTo(_budgets[e]!.first3s),
              reason: '${e.name}: start spread over budget');
          expect(_p95(r, 'interDeviceSpreadMs_steady'), lessThanOrEqualTo(_budgets[e]!.steady),
              reason: '${e.name}: steady spread over budget');
        }
        // Each engine must keep its reason to exist.
        double first(SyncEngineMode e) => _p95(results[e]!, 'interDeviceSpreadMs_first3s');
        expect(first(SyncEngineMode.warm), lessThan(first(SyncEngineMode.classic)));
        expect(first(SyncEngineMode.precise), lessThan(first(SyncEngineMode.warm)));
      });
    }
  }
}
