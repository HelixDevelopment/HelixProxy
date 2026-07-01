# phase5_rotation_guard.sh — LE Phase-5 renewal §11.4.135 standing guard

**Revision:** 1
**Last modified:** 2026-07-01T11:40:00Z
**Authority:** Inherits `constitution/Constitution.md` per §11.4.35. §11.4.18 companion for `tests/letsencrypt/phase5_rotation_guard.sh`.

## Overview

The standing §11.4.135 regression guard for the Let's Encrypt renewal/rotation feature,
with a §11.4.115 `RED_MODE` polarity. It wraps `deploy/letsencrypt/phase5_rotation.sh`.

- **GREEN (`RED_MODE=0`, default):** a real renewal rotation (S1→S2, new serial) happens
  with 0 dropped requests across the swap and the cert-analyzer verifies S2 → **PASS**.
- **RED (`RED_MODE=1`):** the same run with `PHASE5_NO_SURGERY=1` — the deterministic ARI
  trigger removed — MUST NOT renew; `phase5_rotation.sh` exits non-0 and the guard PASSes,
  proving the ARI-window surgery is what triggers the renewal (not the restart alone). If a
  renewal happens WITHOUT the surgery, the guard FAILs (§11.4.7).

## Prerequisites / topology

Boots the hermetic stack (conductor-owned, §11.4.119). 3-way exit — `0`=PASS, `2`=honest
topology SKIP (built image / `podman-compose` absent, §11.4.3 — never a fake pass), else FAIL.
Registered in `tests/run-tests.sh` `test_regression_guards()`. Expensive (~1–2 min; boots
containers) — set `SKIP_LE_ISSUANCE_GUARD=1` to skip the LE guards.

## Usage

```sh
sh tests/letsencrypt/phase5_rotation_guard.sh            # GREEN
RED_MODE=1 sh tests/letsencrypt/phase5_rotation_guard.sh # RED (reproduce: no surgery => no renewal)
```

Runs under `GOMAXPROCS=2 nice -n 19 ionice -c 3`.

## Last verified

2026-07-01 — GREEN PASS (real S1→S2 rotation, 0 dropped, analyzer verifies S2) and RED PASS
(with `PHASE5_NO_SURGERY=1` no renewal fires → guard catches it). Evidence under
`qa-results/regression/` + `qa-results/letsencrypt/phase5_rotation/`.

## Related

- `deploy/letsencrypt/phase5_rotation.sh` — the proof this guards.
- `tests/letsencrypt/phase3_issuance_guard.sh` — the sibling issuance guard.
