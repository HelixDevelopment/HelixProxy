# BUGFIXES

Root-cause-analysed bug fixes for this project, per the Universal
Mandatory Constraints (CLAUDE.md mandate #10). Each entry records the
defect, root cause, affected files, the fix, and a link to the
reproduction/verification evidence.

---

## BUGFIX-0001 — `run-tests.sh` aborts after the first test under `set -e`

- **Type:** Bug (script-internal failure — Helix Constitution §11.4.1)
- **Status:** Fixed
- **Date:** 2026-06-30
- **Affected file:** `tests/run-tests.sh` (`test_result()`)

### Symptom

`bash tests/run-tests.sh` printed only its banner and the first test's
section header, then exited `1` (7 lines of output total) — every test
after the first was silently never run, and no `TEST SUMMARY` was
printed.

### Reproduction (captured, run in-session before the fix)

```
$ bash -c 'set -euo pipefail; x=0; ((x++)); echo "SURVIVED, x=$x"'; echo "exit=$?"
exit=1                      # "SURVIVED" never printed

$ bash tests/run-tests.sh 2>&1 | wc -l
7                           # aborted; exit=1
```

### Root cause (FACT — not a guess, Helix Constitution §11.4.6)

`test_result()` counted with the bash post-increment idiom
`(( TESTS_RUN++ ))`. The arithmetic command `(( expr ))` returns exit
status **1** when `expr` evaluates to **0**. `TESTS_RUN++` is a
*post*-increment, so its value is the value *before* incrementing — `0`
on the very first call — making `(( TESTS_RUN++ ))` return status 1.
The script runs under `set -euo pipefail` (line 7), so that non-zero
status aborted the entire suite at the first `test_result` call, before
any results or the summary could print. The same trap applied to the
first `PASS` (`(( TESTS_PASSED++ ))`) and first `FAIL`
(`(( TESTS_FAILED++ ))`).

This was a **pre-existing** latent defect (the `(( ... ++ ))` idiom was
original); it surfaced while wiring the constitution-inheritance
pre-flight gate in as the first test.

### Fix (at source, Helix Constitution §11.4.1)

Replaced the three post-increment arithmetic commands with the
assignment form, which always returns status 0 and is immune to the
`set -e` trap:

```diff
- ((TESTS_RUN++))
+ TESTS_RUN=$((TESTS_RUN + 1))
- ((TESTS_PASSED++))
+ TESTS_PASSED=$((TESTS_PASSED + 1))
- ((TESTS_FAILED++))
+ TESTS_FAILED=$((TESTS_FAILED + 1))
```

### Verification (captured, run in-session after the fix)

```
$ bash -c 'set -euo pipefail; x=0; x=$((x+1)); echo "SURVIVED, x=$x"'; echo "exit=$?"
SURVIVED, x=1
exit=0

$ bash tests/run-tests.sh 2>&1 | wc -l
28                          # suite now runs to completion (was 7)
# first line of results:
✓ PASS: Constitution inheritance gate (§11.4.35)
```

The suite now executes every test and prints its summary. (Its overall
exit remains non-zero in an environment without the running proxy
services — those are real-infrastructure tests that correctly FAIL/skip
when the live System is absent, Helix Constitution §11.4.11 — that is a
separate, pre-existing, infrastructure-dependent condition, not this
defect.)

> **Cross-reference (§11.4.138):** the "proxy services not running" condition
> noted above was treated as merely environmental. It was not — BUGFIX-0002
> below is the *reason* the proxy would not stay up under rootless Podman.
> Driving the real data path (not just "tests pass") surfaced it.

---

## BUGFIX-0002 — squid crash-loops under rootless Podman (log dir not writable) → proxy never serves

- **Type:** Bug (product defect — end-user-visible: the proxy does not work)
- **Status:** Fixed
- **Date:** 2026-07-01
- **Affected files:** `lib/container-runtime.sh` (`create_directories()`),
  `start` (`init_cache()`)
- **Regression guard:** `tests/regression/log_dir_writable_test.sh`
  (§11.4.135, §11.4.115 `RED_MODE` polarity)
- **Workable item:** #38 (the live-usability proof stream)

### Symptom

A freshly-booted proxy (`./start --no-vpn`, rootless Podman) returned
`http_code=000` for every request through it. `proxy-squid` was not
`(healthy)` — it was restarting in a loop, never accepting a connection,
so **no feature of the proxy worked for the end user** — the exact
"tests pass but the feature can't be used" failure mode §11.4 forbids.

### Reproduction (captured, run in-session before the fix — §11.4.115 RED)

```
# Live boot of the real orchestrator, then curl through the proxy:
$ curl -s -o /dev/null -w '%{http_code}' -x http://127.0.0.1:53128 http://example.com/
000

# squid's own log (read from inside the container) showed the FATAL:
$ podman logs proxy-squid | tail
FATAL: Cannot open '/var/log/squid/access.log' for writing.
       The parent directory must be writeable by the user 'proxy',
       which is the cache_effective_user set in squid.conf.

# Unit reproduction of the orchestrator code path (pre-fix replica):
$ RED_MODE=1 tests/regression/log_dir_writable_test.sh
[PASS] BUGFIX#38 log-dir-writable (RED_MODE=1): RED reproduced:
       pre-fix LOG_DIR mode=755 is NOT world-writable
```

### Root cause (FACT — not a guess, §11.4.6)

Under **rootless** Podman the invoking host uid (1000) maps to the
container's `root`, but every other container uid is remapped through
`/etc/subuid` into a high host range. `squid.conf` sets
`cache_effective_user proxy`, so squid drops privileges to its non-root
`proxy` user — which, on the host, is a high subuid that owns **none** of
the host-created bind-mount dirs. The host `./logs` directory was created
mode `0755` (owner-write only), so the container `proxy` user had only
world `r-x` — no write — and squid `FATAL`ed opening `access.log`, then
crash-looped. The orchestrator already `chmod 777`-ed the **cache**
bind-mount (`init_cache`) for this exact reason, but the **log**
bind-mount was missed — a single missing site of an already-known remedy.

### Fix (at source, §11.4.1 / §11.4.108 SOURCE layer)

Make the squid log bind-mount world-writable in the orchestrator's
dir-init, mirroring the existing cache `chmod 777`. Applied at **both**
self-sufficient sites so it holds regardless of call order:

```diff
# lib/container-runtime.sh  create_directories()
  mkdir -p "$LOG_DIR"
+ chmod 777 "$LOG_DIR"

# start  init_cache()
+ mkdir -p "$LOG_DIR"
+ chmod 777 "$LOG_DIR"
```

### Verification (captured, run in-session after the fix)

**Unit — regression guard, §11.4.115 polarity (RED reproduces, GREEN proves):**

```
$ RED_MODE=1 tests/regression/log_dir_writable_test.sh   # pre-fix replica
[PASS] RED reproduced: LOG_DIR mode=755 NOT world-writable
$ tests/regression/log_dir_writable_test.sh              # real fixed code
[PASS] GREEN: create_directories() made LOG_DIR mode=777 world-writable
```

**§1.1 paired mutation (guard is not a tautology):** stripping the
`chmod 777 "$LOG_DIR"` from `create_directories()` made the GREEN guard
**FAIL** (`REGRESSION: … mode=755 NOT world-writable`, exit 1); the lib
was restored byte-identical (md5 `0128a96b6d467c2da5b7cef8a808e563`
before == after) and the guard PASSed again.

**Live data-plane (§11.4.108 RUNTIME + USER-VISIBLE):** after the fix the
booted proxy serves real HTTP through it:

```
$ curl -x http://127.0.0.1:53128 http://example.com/ -> http_code=200
Via: 1.1 proxy-squid (squid/6.13)
# squid access.log (the file that FATAL'd pre-fix) — real request logged:
1782858066.886  189 10.89.1.249 TCP_MISS/200 951 GET http://example.com/ - HIER_DIRECT/104.20.23.154 text/html
$ podman ps  ->  proxy-squid  Up (healthy)
```

Evidence: `qa-results/regression/bugfix38/`.
