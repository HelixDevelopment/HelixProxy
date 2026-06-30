# Existing Test Scripts — Anti-Bluff Forensic Audit

**Revision:** 1
**Last modified:** 2026-06-30T00:00:00Z
**Authority:** Helix Constitution §11.4 / §11.4.1 / §11.4.2 / §11.4.6 / §11.4.107 / §11.4.138
**Scope:** documentation only — `docs/research/existing_test_bluffs_audit/`. NO test files were
edited; NO containers were booted; NO proxy was run; NO commit/push was performed.

---

## Method (§11.4.6 — facts only, real lines)

Every line number below was read directly from the current working tree on branch
`feature/vpn-aware-dynamic-routing`. The committed data-plane evidence helper library
`tests/lib/evidence.sh` (read in full) is the canonical anti-bluff replacement set:
`assert_egress_ip`, `assert_cache_hit`, `assert_graceful_503`, `assert_no_leak`,
`wg_transfer_delta`, `ab_pass_with_evidence`, `ab_skip_with_reason`.

**Structural FACT:** none of the four audited scripts source `tests/lib/evidence.sh`. They
predate it and use raw `curl`/timing/exit-status/presence assertions exclusively. The
data-plane helpers (`assert_graceful_503`, `assert_no_leak`, `wg_transfer_delta`) are
therefore UNUSED by any existing script — the graceful-503 / kill-switch / WireGuard-byte
data-plane facts are not asserted ANYWHERE today (an absence, not a false PASS).

---

## Summary table

| # | Location (file:line) | Classification | Replacement helper |
|---|---|---|---|
| B1 | `tests/comprehensive-test.sh:400-401` | false-VPN-routing | `assert_egress_ip` (egress≠host) |
| B2 | `tests/comprehensive-test.sh:456-457` | cache-timing-not-header | `assert_cache_hit` (TCP_*HIT) |
| B3 | `tests/comprehensive-test.sh:627,632-639` | exit-status-FAIL-bluff | per-request `%{http_code}` to file |
| B4 | `tests/comprehensive-test.sh:46` (and 50/54/60/636/638) | other (§11.4.1 script-abort) | assignment form `VAR=$((VAR+1))` |
| B5 | `tests/final-verify.sh:74-75` | false-VPN-routing | `assert_egress_ip` (egress≠host) |
| B6 | `tests/verify-proxy.sh:49` | false-VPN-routing | `assert_egress_ip` (egress≠host) |
| B7 | `tests/run-tests.sh:311` (and `:273`) | presence-only / PASS-by-default-for-skip | `ab_skip_with_reason` |
| B8 | `tests/comprehensive-test.sh:463-467,542-560` | presence-only (exit-status) | `ab_pass_with_evidence` |

Lower-severity / structural notes follow the entries.

---

## B1 — `comprehensive-test.sh:400-401` — false-VPN-routing (THE §15 bluff)

**Location / offending code** (`tests/comprehensive-test.sh`, `test_vpn_routing`):
```
399	    if [[ "$http_proxy_ip" != "unknown" && "$host_ip" != "unknown" ]]; then
400	        if [[ "$http_proxy_ip" == "$host_ip" ]]; then
401	            test_result "VPN routing (HTTP proxy uses host VPN)" "PASS" "Both IPs: $host_ip"
```

**Claim:** "VPN routing (HTTP proxy uses host VPN)" PASSES.

**Why it's a bluff:** It declares PASS precisely when the egress IP seen through the proxy
EQUALS the host's real direct IP. That equality is the proof that traffic was **NOT** routed
through any VPN — both paths exit via the same address. `evidence.sh:222-224` FAILS this exact
case (`egress IP $observed == host real IP — traffic NOT routed via VPN (§15 bluff)`). The test
asserts the inverse of the truth: it greens a no-VPN configuration. It also never compares
against an EXPECTED VPN exit IP, so even a different IP would not prove the *intended* tunnel.

**Classification:** false-VPN-routing.

**Corrected assertion design (before → after):**
```sh
# BEFORE (comprehensive-test.sh:399-404) — PASS when proxy IP == host IP
if [[ "$http_proxy_ip" == "$host_ip" ]]; then
    test_result "VPN routing (HTTP proxy uses host VPN)" "PASS" "Both IPs: $host_ip"
fi

# AFTER — data-plane proof: egress through proxy must equal the EXPECTED VPN exit
# AND differ from the host's real IP.
. "$SCRIPT_DIR/lib/evidence.sh"
HOST_REAL_IP=$(get_external_ip)
EXPECTED_EXIT_IP="${VPN_EXIT_IP:?set expected tunnel exit IP}"
assert_egress_ip "http://localhost:$http_port" "$EXPECTED_EXIT_IP" "$HOST_REAL_IP"
```

**RED plan (P10):** With the tunnel UP and `VPN_EXIT_IP` set to the real exit, `assert_egress_ip`
PASSES; force the §15 condition (route the proxy via the host uplink so egress==host) and the
assertion FAILS — reproducing this bluff on the running system. Permanent guard (§11.4.135):
register the `assert_egress_ip` invocation as a standing regression test (`RED_MODE=1` captures
egress==host on the broken config, `RED_MODE=0` is the GREEN guard asserting egress≠host).

---

## B2 — `comprehensive-test.sh:456-457` — cache-timing-not-header

**Location / offending code** (`test_caching`):
```
443	    curl -s --max-time 30 --proxy "http://localhost:$port" "$test_url" -o /dev/null 2>/dev/null
...
449	    curl -s --max-time 30 --proxy "http://localhost:$port" "$test_url" -o /dev/null 2>/dev/null
...
456	    if [[ $second_time -lt $first_time ]]; then
457	        test_result "Cache improves response time" "PASS" "Second request faster"
```

**Claim:** "Cache improves response time" PASSES when the second request is wall-clock faster.

**Why it's a bluff:** Timing is not a cache fact. A second request can be faster from TCP warmup,
DNS cache, upstream CDN edge, or jitter — with the Squid object NEVER cached. It proves no
data-plane cache HIT. (Note the `-o /dev/null` discards body and no `-w` captures any header, so
not even `X-Cache` is observed.) `evidence.sh:240-265` requires the Squid `access.log` to carry a
URL-specific `TCP_*HIT` result code — the data-plane corroboration. Timing is also non-deterministic
(§11.4.50). Mitigating note: line 459 correctly degrades to SKIP when the second request is slower,
so it is not a hard PASS-bluff in that branch — but the PASS branch (456-457) is the bluff.

**Classification:** cache-timing-not-header.

**Corrected assertion design (before → after):**
```sh
# BEFORE (comprehensive-test.sh:456-457) — timing comparison
if [[ $second_time -lt $first_time ]]; then
    test_result "Cache improves response time" "PASS" "Second request faster"
fi

# AFTER — require an actual Squid TCP_*HIT for THIS url in the access.log
. "$SCRIPT_DIR/lib/evidence.sh"
curl -s --proxy "http://localhost:$port" "$test_url" -o /dev/null   # warm
curl -s --proxy "http://localhost:$port" "$test_url" -o /dev/null   # should HIT
assert_cache_hit "$cache_dir/squid/access.log" "$test_url"
```

**RED plan (P10):** Request a cacheable URL twice through the running proxy; `assert_cache_hit`
PASSES only when `access.log` shows `TCP_MEM_HIT`/`TCP_HIT` for that URL; against a
caching-disabled config every line is `TCP_MISS` and the assertion FAILS — reproducing the bluff.
Permanent guard (§11.4.135): the `assert_cache_hit` call is the standing regression test.

---

## B3 — `comprehensive-test.sh:627,632-639` — exit-status-FAIL-bluff (concurrent)

**Location / offending code** (`test_concurrent`):
```
624	            curl -s --max-time 30 \
625	                --proxy "http://localhost:$port" \
626	                "https://httpbin.org/get" \
627	                -o /dev/null -w "%{http_code}" 2>/dev/null
628	        ) &
...
632	    for job in $(jobs -p); do
633	        local code
634	        code=$(wait "$job" 2>/dev/null || echo "000")
635	        if [[ "$code" == "200" ]]; then
636	            ((success++))
```

**Claim:** "Concurrent connections (10)" PASSES when `success >= 8`.

**Why it's a bluff:** The per-request HTTP status is never captured. The `-w "%{http_code}"` output
(line 627) is printed to the backgrounded subshell's stdout and discarded — it is not assigned
anywhere. `code=$(wait "$job" ...)` (line 634) captures the **job exit status**, not the HTTP code:
`wait` emits no stdout, so on a successful job `code=""`, and on a failed job `code="000"` via the
`|| echo "000"` fallback. `[[ "$code" == "200" ]]` (635) can therefore NEVER be true, so `success`
stays 0 and the verdict bears no relation to the data-plane fact (did each of 10 requests actually
return 200 through the proxy). It conflates process exit-status with HTTP outcome — the §11.4.1
class where the verdict is decoupled from real product behaviour.

**Classification:** exit-status-FAIL-bluff.

**Corrected assertion design (before → after):**
```sh
# BEFORE — captures job exit status, never the HTTP code
code=$(wait "$job" 2>/dev/null || echo "000")
[[ "$code" == "200" ]] && ((success++)) || ((failed++))

# AFTER — write each request's %{http_code} to its own file, read it back per-request
tmpd=$(mktemp -d)
for i in $(seq 1 10); do
    ( curl -s --max-time 30 --proxy "http://localhost:$port" \
        "https://httpbin.org/get" -o /dev/null -w '%{http_code}' \
        > "$tmpd/code.$i" 2>/dev/null ) &
done
wait
success=0
for i in $(seq 1 10); do
    [ "$(cat "$tmpd/code.$i")" = "200" ] && success=$((success + 1))
done
# emit evidence file + ab_pass_with_evidence (§11.4.69)
printf 'success=%d/10\n' "$success" > "$tmpd/concurrent.evidence"
[ "$success" -ge 8 ] && ab_pass_with_evidence "concurrent 10x 200" "$tmpd/concurrent.evidence"
rm -rf "$tmpd"
```

**RED plan (P10):** Fire 10 concurrent requests through the running proxy; with per-file
`%{http_code}` capture the test PASSES only on ≥8 real 200s; throttle/break the proxy so requests
return 503/000 and the assertion FAILS. Permanent guard (§11.4.135): the per-request 200-count +
`ab_pass_with_evidence` evidence file is the standing regression test.

---

## B4 — `comprehensive-test.sh:46` — §11.4.1 script-internal abort (other)

**Location / offending code** (`test_result`, under `set -euo pipefail` at line 7):
```
21	TESTS_RUN=0
...
46	    ((TESTS_RUN++))
...
50	            ((TESTS_PASSED++))
...
54	            ((TESTS_FAILED++))
...
636	            ((success++))
638	            ((failed++))
```

**Claim:** the suite counts tests and runs to a summary.

**Why it's a bluff (FACT-grade):** Under `set -e`, a standalone `((VAR++))` whose pre-increment
value is `0` evaluates the arithmetic expression to `0`, which makes `(( ))` return exit status 1
and aborts the script. The very first `test_result` call hits `((TESTS_RUN++))` with `TESTS_RUN=0`
→ exit 1 → suite aborts before exercising any product behaviour. This is the §11.4.1 FAIL-bluff
class (a script-internal failure, not a product defect). This is not speculation: the sibling
`tests/run-tests.sh:32-37` documents EXACTLY this defect and its fix in a committed comment
("use assignment form, NOT (( VAR++ )). Under `set -e` a post-increment whose prior value is 0
returns exit status 1 and aborts the whole suite ... See docs/issues/fixed/BUGFIXES.md").
`comprehensive-test.sh` was never migrated to the assignment form.

**Classification:** other (§11.4.1 script-internal FAIL-bluff).

**Corrected assertion design (before → after):**
```sh
# BEFORE (comprehensive-test.sh:46) — aborts under set -e when counter is 0
((TESTS_RUN++))

# AFTER — the run-tests.sh-proven assignment form
TESTS_RUN=$((TESTS_RUN + 1))
```
Apply identically at lines 50, 54, 60, 636, 638.

**RED plan (P10):** Run `bash tests/comprehensive-test.sh` against the running stack; capture that
it exits non-zero with zero `PASS:` lines emitted (the abort). After the assignment-form fix the
suite runs to summary. Permanent guard (§11.4.135): a meta-test that `bash -c` runs the script and
asserts ≥1 emitted result line + `sh -n`/`bash -n` parse (§11.4.67).

---

## B5 — `final-verify.sh:74-75` — false-VPN-routing

**Location / offending code:**
```
72	host_ip=$(curl -s -4 --max-time 15 https://ifconfig.me 2>/dev/null || echo "unknown")
73	proxy_ip=$(curl -s -4 --max-time 15 --proxy http://localhost:${HTTP_PROXY_PORT} https://ifconfig.me 2>/dev/null || echo "unknown")
74	if [[ "$host_ip" == "$proxy_ip" && "$host_ip" != "unknown" ]]; then
75	    test_pass "VPN routing verified (IP: $host_ip)"
```

**Claim:** "VPN routing verified" PASSES.

**Why it's a bluff:** Identical §15 logic to B1 — PASS when proxy egress IP == host real IP, i.e.
when there is NO VPN diversion. No expected-exit comparison. `evidence.sh:213-232` is the corrective
contract (FAIL on egress==host, require egress==expected exit). (Lines 36-68 of this file — the
HTTP/HTTPS/SOCKS `%{http_code}` connectivity checks — are legitimate forwarding evidence and are
NOT bluffs.)

**Classification:** false-VPN-routing.

**Corrected assertion design (before → after):**
```sh
# BEFORE (final-verify.sh:74-75)
[[ "$host_ip" == "$proxy_ip" && "$host_ip" != "unknown" ]] && test_pass "VPN routing verified"

# AFTER
. "$SCRIPT_DIR/lib/evidence.sh"
assert_egress_ip "http://localhost:${HTTP_PROXY_PORT}" "${VPN_EXIT_IP:?}" "$host_ip"
```

**RED plan (P10):** identical to B1 (egress==host reproduces the bluff; tunnel-up egress==expected
exit is the GREEN guard). Permanent guard (§11.4.135): standing `assert_egress_ip`.

---

## B6 — `verify-proxy.sh:49` — false-VPN-routing

**Location / offending code** (the comment on line 46 self-describes the bluff):
```
46	# 5. VPN Routing - check that proxy uses same IP as host
47	host_ip=$(curl -s -4 --max-time 15 https://ifconfig.me 2>/dev/null || echo "unknown")
48	proxy_ip=$(curl -s -4 --max-time 15 --proxy http://localhost:${HTTP_PROXY_PORT} https://ifconfig.me 2>/dev/null || echo "unknown")
49	[[ "$host_ip" == "$proxy_ip" && "$host_ip" != "unknown" ]] && test_pass "VPN routing verified (IP: $host_ip)" || test_fail "VPN routing (host: $host_ip, proxy: $proxy_ip)"
```

**Claim:** "VPN routing verified" PASSES when host IP == proxy IP.

**Why it's a bluff:** Same §15 inversion as B1/B5; the line-46 comment literally encodes the wrong
invariant ("proxy uses same IP as host"). Same `assert_egress_ip` correction.

**Classification:** false-VPN-routing.

**Corrected assertion design (before → after):**
```sh
# BEFORE (verify-proxy.sh:49)
[[ "$host_ip" == "$proxy_ip" && "$host_ip" != "unknown" ]] && test_pass "VPN routing verified"

# AFTER
. "$SCRIPT_DIR/lib/evidence.sh"
assert_egress_ip "http://localhost:${HTTP_PROXY_PORT}" "${VPN_EXIT_IP:?}" "$host_ip"
```

**RED plan (P10):** identical to B1. Permanent guard (§11.4.135): standing `assert_egress_ip`.

---

## B7 — `run-tests.sh:311` (and `:273`) — presence-only / PASS-by-default-for-skip

**Location / offending code:**
```
272	    if [[ "${USE_VPN:-false}" != "true" ]]; then
273	        test_result "VPN disabled" "PASS" "Skipped"
...
310	    if [[ "${RUN_STARTUP_TESTS:-false}" != "true" ]]; then
311	        test_result "Startup tests" "PASS" "Skipped (set RUN_STARTUP_TESTS=true)"
```

**Claim:** "VPN disabled" and "Startup tests" count as PASSES.

**Why it's a bluff:** `run-tests.sh`'s `test_result` (lines 27-47) has only PASS/FAIL — no SKIP
state — so skipped/disabled paths are recorded as PASS and inflate `TESTS_PASSED`. A skipped test
is honest non-evidence and MUST be SKIP, not PASS-by-default (§11.4.3 forbids PASS-by-default). More
broadly, `run-tests.sh` contains **zero data-plane assertions** — it never issues a single request
through the proxy/SOCKS/VPN/cache; every check is filesystem/config/runtime presence
(`test_directories` 82-106, `test_scripts` 111-131, `test_config_files` 136-153,
`test_container_runtime` 187-215 daemon-running=PASS). Its banner ("Comprehensive tests for all
components") overstates what it proves.

**Classification:** presence-only (PASS-by-default-for-skip).

**Corrected assertion design (before → after):**
```sh
# BEFORE (run-tests.sh:273 / :311) — skip recorded as PASS
test_result "VPN disabled" "PASS" "Skipped"

# AFTER — honest SKIP via the §11.4.69 closed-set helper
. "$SCRIPT_DIR/lib/evidence.sh"
ab_skip_with_reason "VPN routing" "feature_disabled_by_config"   # USE_VPN != true
ab_skip_with_reason "service startup" "operator_attended"        # RUN_STARTUP_TESTS != true
# (and add a real SKIP bucket to test_result so skips do not inflate TESTS_PASSED)
```

**RED plan (P10):** run `run-tests.sh` with `USE_VPN=false`; today it prints a PASS for "VPN
disabled" and the green summary hides that VPN was never exercised. After the fix it emits a SKIP
and the summary no longer counts it as passed. Permanent guard (§11.4.135): a meta-test asserting
no `PASS:` line carries the word "Skipped".

---

## B8 — `comprehensive-test.sh:463-467, 542-560` — presence-only (exit-status command checks)

**Location / offending code:**
```
463	    if "$PROJECT_ROOT/cache" stats &>/dev/null; then
464	        test_result "Cache stats command works" "PASS"
...
542	    if ./cache stats &>/dev/null; then
543	        test_result "Cache stats command" "PASS"
...   (also ./cache size 549-553, ./cache list 555-560, ./status 512-530)
```

**Claim:** "Cache stats command works", "Status command works", etc. PASS.

**Why it's a bluff:** Output is sent to `&>/dev/null` and only the exit status is checked. A command
that exits 0 while emitting empty/garbage output PASSES — no assertion on the substance of the
stats/status. This is presence/exit-status, not a data-plane fact (e.g. a real cache-stats number,
or a status field reflecting a running service). Lower severity than B1-B3 because the label
("command works") is narrowly honest, but it still greens a non-functional output path.

**Classification:** presence-only (exit-status).

**Corrected assertion design (before → after):**
```sh
# BEFORE
if ./cache stats &>/dev/null; then test_result "Cache stats command works" "PASS"; fi

# AFTER — capture output, assert a substantive field, cite it as evidence
ev=$(mktemp); ./cache stats > "$ev" 2>&1
grep -Eq 'Cache (Hits|Size)|TCP_.*HIT|[0-9]+ KB' "$ev" \
    && ab_pass_with_evidence "cache stats reports real figures" "$ev"
```

**RED plan (P10):** run `./cache stats` against the live stack; the corrected check PASSES only when
the output contains real hit/size figures; against a stopped cache it produces empty output and the
assertion FAILS. Permanent guard (§11.4.135): the `ab_pass_with_evidence` evidence file.

---

## Verified NOT-a-bluff / suspected-but-absent (§11.4.6 honesty)

- **HTTP/HTTPS/SOCKS connectivity checks** in all three live scripts
  (`comprehensive-test.sh:299-335, 349-370`; `final-verify.sh:36-68`; `verify-proxy.sh:31-44`) read
  real per-request `%{http_code}` (204/200/301/302) — these ARE legitimate forwarding evidence, not
  bluffs.
- **`run-tests.sh` port check is INVERTED, not a feature PASS.** The prompt-suspected "port-open
  treated as feature PASS" is NOT present in `run-tests.sh`: `test_ports` (lines 230-236) treats a
  LISTENING port as **FAIL** ("Port in use") and a free port as PASS — it is a pre-start
  availability gate, not a feature assertion. (The port-listening=PASS pattern lives in
  `comprehensive-test.sh:267-278`, where the label "port listening" is honest presence, not a
  claimed proxy feature.)
- **`comprehensive-test.sh` container-running checks** (lines 233-251) are presence-only but the
  labels ("Squid container running") accurately describe a status check, not a user-visible feature
  — lower severity, noted not entry-rated.
- **`comprehensive-test.sh:411-412`** ("HTTP and SOCKS use same routing") compares two proxy egress
  IPs — a valid metamorphic relation — but it is built on the same `get_proxy_ip` plumbing as B1; it
  is not itself a false-routing bluff (it does not assert egress==host).
- No `assert_graceful_503`, kill-switch / no-leak, or WireGuard-byte-delta test exists in any of the
  four scripts — these data-plane facts are simply **unasserted today** (an absence to be filled in
  P10 using `assert_graceful_503` / `assert_no_leak` / `wg_transfer_delta`), not a false PASS to fix.
