tests/dynamic/baselines/ — committed performance baselines (§11.4.169(13))
===========================================================================

Purpose
-------
This directory is the STABLE, COMMITTED (git-tracked) home for the performance
baselines that the dynamic benchmark suite ratchets against. It exists so the
regression check actually PERSISTS across clean clones and runs — unlike the
former default under qa-results/, which is gitignored (.gitignore: `qa-results/`)
and therefore never survived a fresh checkout, silently DISARMING the ratchet.

Files
-----
benchmark_p95.baseline   The p95 latency (integer milliseconds, one number on
                         the first line) that tests/dynamic/suites/benchmark_suite.sh
                         compares each run's measured p95 against. ABSENT until
                         the first real P10 run SEEDS it from a genuine
                         measurement (never a fabricated value — §11.4.6).

Seed / arm workflow (§11.4.169(13) / §11.4.1)
---------------------------------------------
1. First real run with the live `dynamic` stack up and NO baseline present:
   the suite MEASURES p95, WRITES benchmark_p95.baseline from that real number,
   and emits a SKIP-with-reason (`feature_disabled_by_config`) — it does NOT
   emit a budget-only PASS. The ratchet is "not yet armed".
2. Commit benchmark_p95.baseline (the operator reviews the seeded number).
3. Every subsequent run compares measured p95 vs the committed baseline; growth
   beyond BENCH_REGRESS_PCT (default 25%) is a regression FAIL — a finding.
   The baseline is NEVER auto-refreshed on PASS (auto-refresh would let a
   regression drift in as the new "normal").

To intentionally move the baseline (e.g. after an accepted perf change), delete
or overwrite benchmark_p95.baseline and re-run to re-seed, then commit the new
value with a rationale.

Guarded by
----------
tests/regression/benchmark_baseline_ratchet_test.sh — the standing §11.4.135
fixture-driven regression guard proving a regressed measurement FAILs and an
in-tolerance one PASSes.
