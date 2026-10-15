# Benchmark data

| Directory | Contents |
|---|---|
| `results/simulated/` | **SIMULATED** results from `packages/syncsphere_core/bin/benchmark.dart --suite full --seed 42 --sample-every 10`. Each scenario has `<name>.json` (scenario plus metrics) and `<name>.samples.jsonl` (every 10th ground-truth sample); `summary.json`/`summary.md` aggregate them. The devices and networks are *models*; these are not hardware measurements. |
| `results/real/` | Reserved for real-device runs: acoustic recordings analyzed with `tools/onset_skew.py`, plus software-estimated logs. Empty: no real-device data has been collected yet. |
| `out/` | Scratch output (git-ignored). |

Regenerate the simulated data:

```bash
cd packages/syncsphere_core
dart run bin/benchmark.dart --suite full --out ../../benchmarks/results/simulated --sample-every 10
```

Recompute the statistics independently:

```bash
python3 tools/analyze_samples.py benchmarks/results/simulated/*.samples.jsonl
```

Because the raw files keep only every 10th sample, the Python percentiles differ slightly from the summary, which uses
all samples.
