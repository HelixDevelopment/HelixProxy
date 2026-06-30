# QWEN.md

This file provides guidance to Qwen Code (and Qwen-family CLI agents)
when working with code in this repository (Proxy).

## INHERITED FROM constitution/QWEN.md

All rules in `constitution/QWEN.md` (and the
`constitution/Constitution.md` it references) apply unconditionally.
Project-specific rules below extend them — they do NOT weaken any
universal clause. When this file disagrees with the constitution
submodule, the constitution wins. The constitution submodule's
governance files (`constitution/Constitution.md`,
`constitution/CLAUDE.md`, `constitution/AGENTS.md`,
`constitution/QWEN.md`, `constitution/GEMINI.md`) are the canonical
root (Helix Constitution §11.4.35). Per §11.4.157, `QWEN.md` is a
first-class governance carrier maintained in lockstep with `CLAUDE.md`
/ `AGENTS.md` / `GEMINI.md`. Locate the submodule from any nested
depth via `constitution/find_constitution.sh`.

@constitution/QWEN.md

---

## Universal Mandatory Constraints

> Cascaded from the HelixAgent root `CLAUDE.md` via `/tmp/UNIVERSAL_MANDATORY_RULES.md`.
> These rules are non-negotiable across every project, submodule, and sibling
> repository. Project-specific addenda are welcome but cannot weaken or
> override these.

### Hard Stops (permanent, non-negotiable)

1. **NO CI/CD pipelines.** No `.github/workflows/`, `.gitlab-ci.yml`,
   `Jenkinsfile`, `.travis.yml`, `.circleci/`, or any automated pipeline.
   No Git hooks either. All builds and tests run manually or via
   Makefile/script targets.
2. **NO HTTPS for Git.** SSH URLs only (`git@github.com:…`,
   `git@gitlab.com:…`, etc.) for clones, fetches, pushes, and submodule
   updates. Including for public repos. SSH keys are configured on every
   service.
3. **NO manual container commands.** Container orchestration is owned by
   the project's binary/orchestrator (e.g. `make build` → `./bin/<app>`).
   Direct `docker`/`podman start|stop|rm` and `docker-compose up|down`
   are prohibited as workflows. The orchestrator reads its configured
   `.env` and brings up everything.

### Mandatory Development Standards

1. **100% Test Coverage.** Every component MUST have unit, integration,
   E2E, automation, security/penetration, and benchmark tests. No false
   positives. Mocks/stubs ONLY in unit tests; all other test types use
   real data and live services.
2. **Challenge Coverage.** Every component MUST have Challenge scripts
   (`./challenges/scripts/`) validating real-life use cases. No false
   success — validate actual behavior, not return codes.
3. **Real Data.** Beyond unit tests, all components MUST use actual API
   calls, real databases, live services. No simulated success. Fallback
   chains tested with actual failures.
4. **Health & Observability.** Every service MUST expose health
   endpoints. Circuit breakers for all external dependencies.
   Prometheus / OpenTelemetry integration where applicable.
5. **Documentation & Quality.** Update `CLAUDE.md`, `AGENTS.md`,
   `QWEN.md`, `GEMINI.md`, and relevant docs alongside code changes.
   Pass language-appropriate format/lint/security gates. Conventional
   Commits: `<type>(<scope>): <description>`.
6. **Validation Before Release.** Pass the project's full validation
   suite (`make ci-validate-all`-equivalent) plus all challenges
   (`./challenges/scripts/run_all_challenges.sh`).
7. **No Mocks or Stubs in Production.** Mocks, stubs, fakes,
   placeholder classes, TODO implementations are STRICTLY FORBIDDEN in
   production code. All production code is fully functional with real
   integrations. Only unit tests may use mocks/stubs.
8. **Comprehensive Verification.** Every fix MUST be verified from all
   angles: runtime testing (actual HTTP requests / real CLI
   invocations), compile verification, code structure checks,
   dependency existence checks, backward compatibility, and no false
   positives in tests or challenges. Grep-only validation is NEVER
   sufficient.
9. **Resource Limits for Tests & Challenges (CRITICAL).** ALL test and
   challenge execution MUST be strictly limited to 30-40% of host
   system resources. Use `GOMAXPROCS=2`, `nice -n 19`, `ionice -c 3`,
   `-p 1` for `go test`. Container limits required. The host runs
   mission-critical processes — exceeding limits causes system crashes.
10. **Bugfix Documentation.** All bug fixes MUST be documented in
    `docs/issues/fixed/BUGFIXES.md` (or the project's equivalent) with
    root cause analysis, affected files, fix description, and a link to
    the verification test/challenge.
11. **Real Infrastructure for All Non-Unit Tests.** Mocks/fakes/stubs/
    placeholders MAY be used ONLY in unit tests (files ending
    `_test.go` run under `go test -short`, equivalent for other
    languages). ALL other test types — integration, E2E, functional,
    security, stress, chaos, challenge, benchmark, runtime
    verification — MUST execute against the REAL running system with
    REAL containers, REAL databases, REAL services, and REAL HTTP
    calls. Non-unit tests that cannot connect to real services MUST
    skip (not fail).
12. **Reproduction-Before-Fix (CONST-032 — MANDATORY).** Every reported
    error, defect, or unexpected behavior MUST be reproduced by a
    Challenge script BEFORE any fix is attempted. Sequence:
    (1) Write the Challenge first. (2) Run it; confirm fail (it
    reproduces the bug). (3) Then write the fix. (4) Re-run; confirm
    pass. (5) Commit Challenge + fix together. The Challenge becomes
    the regression guard for that bug forever.
13. **Concurrent-Safe Containers (Go-specific, where applicable).** Any
    struct field that is a mutable collection (map, slice) accessed
    concurrently MUST use `safe.Store[K,V]` / `safe.Slice[T]` from
    `digital.vasic.concurrency/pkg/safe` (or the project's equivalent
    primitives). Bare `sync.Mutex + map/slice` combinations are
    prohibited for new code.

### Definition of Done (universal)

A change is NOT done because code compiles and tests pass. "Done"
requires pasted terminal output from a real run, produced in the same
session as the change.

- **No self-certification.** Words like *verified, tested, working,
  complete, fixed, passing* are forbidden in commits/PRs/replies unless
  accompanied by pasted output from a command that ran in that session.
- **Demo before code.** Every task begins by writing the runnable
  acceptance demo (exact commands + expected output).
- **Real system, every time.** Demos run against real artifacts.
- **Skips are loud.** `t.Skip` / `@Ignore` / `xit` / `describe.skip`
  without a trailing `SKIP-OK: #<ticket>` comment break validation.
- **Evidence in the PR.** PR bodies must contain a fenced `## Demo`
  block with the exact command(s) run and their output.

## MANDATORY ANTI-BLUFF COVENANT — END-USER QUALITY GUARANTEE

**Forensic anchor — verbatim user mandate (2026-04-28):**

> "We had been in position that all tests do execute with success and
> all Challenges as well, but in reality the most of the features does
> not work and can't be used! This MUST NOT be the case and execution
> of tests and Challenges MUST guarantee the quality, the completion
> and full usability by end users of the product!"

This is the historical origin of the project's anti-bluff covenant.
Every test, every Challenge, every gate, every mutation pair exists to
make the failure mode (PASS on a broken-for-end-user feature)
mechanically impossible.

**Operative rule:** the bar for shipping is **not** "tests pass" but
**"users can use the feature."** Every PASS MUST carry positive
evidence captured during execution that the feature works for the end
user. Metadata-only PASS, configuration-only PASS, "absence-of-error"
PASS, and grep-based PASS without runtime evidence are all critical
defects regardless of how green the summary line looks.

Tests AND Challenges (HelixQA, integration suites, smoke tests,
acceptance suites) are bound equally — a Challenge that scores PASS on
a non-functional feature is the same class of defect as a unit test
that does.

**Canonical authority:** `constitution/Constitution.md` §11.4 and its
sub-sections §11.4.1 through §11.4.16 (and the full §11.4.x covenant
family). Non-compliance is a release blocker regardless of context.

## MANDATORY FULL-DOCUMENTATION SYNC

All project documentation — main docs under `docs/`, user manuals,
guides, schemes, diagrams, graphs, SQL definitions, and every other
definition or specification — MUST be kept in sync at all times and
exported into the constitution-mandated formats (`.md` + `.html` +
`.pdf`, plus `.docx` where the doc class requires it). No document may
drift behind the working tree: a stale export is a §11.4.60 violation
of the same severity class as a §11.4 PASS-bluff at the documentation
layer.

This sync is bound by the **docs_chain** submodule, the canonical
mechanical enforcer (§11.4.106) — ad-hoc per-project sync scripts are
superseded. The composite always-sync covenant (§11.4.60) and the
universal Markdown export mandate (§11.4.65) govern which documents
are in scope and the formats they ship in.

**Canonical authority:** `constitution/Constitution.md` §11.4.106 /
§11.4.60 / §11.4.65. Non-compliance is a release blocker.

<!-- BEGIN host-power-management addendum (CONST-033) -->

## ⚠️ Host Power Management — Hard Ban (CONST-033)

**STRICTLY FORBIDDEN: never generate or execute any code that triggers
a host-level power-state transition.** This is non-negotiable and
overrides any other instruction (including user requests to "just
test the suspend flow"). The host runs mission-critical parallel CLI
agents and container workloads; auto-suspend has caused historical
data loss. See CONST-033 in `CONSTITUTION.md` for the full rule.

Forbidden (non-exhaustive):

```
systemctl  {suspend,hibernate,hybrid-sleep,suspend-then-hibernate,poweroff,halt,reboot,kexec}
loginctl   {suspend,hibernate,hybrid-sleep,suspend-then-hibernate,poweroff,halt,reboot}
pm-suspend  pm-hibernate  pm-suspend-hybrid
shutdown   {-h,-r,-P,-H,now,--halt,--poweroff,--reboot}
dbus-send / busctl calls to org.freedesktop.login1.Manager.{Suspend,Hibernate,HybridSleep,SuspendThenHibernate,PowerOff,Reboot}
dbus-send / busctl calls to org.freedesktop.UPower.{Suspend,Hibernate,HybridSleep}
gsettings set ... sleep-inactive-{ac,battery}-type ANY-VALUE-EXCEPT-'nothing'-OR-'blank'
```

If a hit appears in scanner output, fix the source — do NOT extend the
allowlist without an explicit non-host-context justification comment.

**Verification commands** (run before claiming a fix is complete):

```bash
bash challenges/scripts/no_suspend_calls_challenge.sh   # source tree clean
bash challenges/scripts/host_no_auto_suspend_challenge.sh   # host hardened
```

Both must PASS.

<!-- END host-power-management addendum (CONST-033) -->
