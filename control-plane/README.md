# Helix Proxy — Control-Plane (Go module)

**Revision:** 1
**Last modified:** 2026-06-30T00:00:00Z
**Status:** Scaffold (plan T0.5 — compiling skeleton, no business logic yet)
**Spec:** [`docs/superpowers/specs/2026-06-30-vpn-aware-proxy-extension-design.md`](../docs/superpowers/specs/2026-06-30-vpn-aware-proxy-extension-design.md) §4, §18
**Plan:** [`docs/superpowers/plans/2026-06-30-vpn-aware-proxy-extension-plan.md`](../docs/superpowers/plans/2026-06-30-vpn-aware-proxy-extension-plan.md) T0.5
**Authority:** Inherits the Helix Constitution submodule (`constitution/Constitution.md`) per §11.4.35.

---

## What this is

The **control-plane** is the new Go module that adds VPN-aware dynamic routing to
the existing OpenVPN/Squid/Dante stack **without sitting in the request byte
path** (spec §4 principle). Squid keeps proxying + caching; the control-plane is a
**config-compiler + health-publisher + ACL helper + admin API** living *beside*
the data path. It talks to Postgres (data model, spec §6) and Redis (live
data-plane state bus, spec §7).

> **SCAFFOLD STATE.** This is plan task **T0.5** only: a compiling skeleton with
> clear package boundaries. Every `cmd` `main()` prints a version/usage line and
> wires its package contracts; every `internal/` package defines documented
> interfaces/types with **no business logic**. Each file is marked
> `SCAFFOLD (Phase N): real impl lands in <phase>`. Per §11.4.27, placeholders/
> TODOs are permitted in scaffolds — the eventual production code must be real,
> fully wired, and anti-bluff-proven.

## Module

`module digital.vasic.helixproxy/controlplane` (Go 1.22+). No external
dependencies yet — the scaffold compiles against the standard library only;
real deps (pgx, go-redis, gobreaker, OTel, templ/htmx, prometheus) are added in
their respective phases.

## Layout & spec §4 mapping

```
control-plane/
  go.mod
  cmd/
    healthd/      → spec §4 component 1  vpn-health-publisher   (plan Phase 3)
    compiler/     → spec §4 component 2  config-compiler        (plan Phase 4)
    acl-helper/   → spec §4 component 3  external-acl-helper    (plan Phase 5)
    api/          → spec §4 component 4  control-API + admin UI (plan Phase 6)
  internal/
    vpn/          health as a DATA-PLANE FACT: HealthSnapshot{rx,tx,handshake,egress_ip},
                  Prober, HealthEvaluator, Publisher          (spec §4.1/§5/§7 · Phase 3)
    redis/        StatusBus contract — fail-closed live state bus
                  (vpn:status:<profile>, vpn:events, route:<target>)  (spec §7 · Phase 2)
    store/        Queries contract over the Postgres data model
                  (profiles/targets/rules/tiers/users/audit)          (spec §6 · Phase 2)
    routing/      Compiler — renders Squid include + Dante routes + PAC (spec §8/§9 · Phase 4)
    breaker/      Decider — per-target circuit-breaker + tunnel tier-failover (spec §11① · Phase 5)
    pac/          Generator — FindProxyForURL PAC artifact            (spec §11⑤ · Phase 6)
    api/          Server + Config (REST/SSE/metrics/PAC/mTLS)         (spec §4.4/§11⑥ · Phase 6)
    otel/         Init/ShutdownFunc — in-process OTel observability   (spec §11③ · Phase 7)
```

### Command → component, in one line each
- **`cmd/healthd`** polls gluetun + `wg show transfer` Δ + an egress probe and
  writes `vpn:status:<profile>` / publishes `vpn:events`. Health is a data-plane
  fact (tx-Δ>0 AND fresh handshake AND egress≠host), never "configured".
- **`cmd/compiler`** reads Postgres and renders the Squid generated include
  (per-tunnel `cache_peer`, `deny_info 503`), the Dante routes, and the PAC file;
  structural reload only — up/down flows through Redis per request.
- **`cmd/acl-helper`** is the Squid `external_acl_type` binary: per request it
  reads Redis and returns `OK tag=<tunnel>` or `ERR` (graceful 503), embedding
  the circuit-breaker + tier-failover decision and failing closed.
- **`cmd/api`** serves the REST CRUD + SSE status + Prometheus `/metrics` +
  `FindProxyForURL` PAC endpoint over mTLS, with the templ/htmx admin UI that
  replaces the `traefik/whoami` placeholder.

## Build & dev targets

Local dev convenience (a Go toolchain on the host):

```
make fmt     # gofmt -l (lists files needing formatting; empty == clean)
make vet     # go vet ./...
make build   # go build ./...   (produces nothing tracked; out/ is git-ignored)
make test    # go test ./...    (no tests yet in the scaffold)
```

> **PRODUCTION BUILD — §11.4.173.** The local `make` targets are **dev-convenience
> only**. The production build MUST run **inside a build container provisioned via
> the `vasic-digital/containers` submodule, distributed to the remote build host**,
> with artifacts brought back — never a bare-host build. That wiring lands in plan
> **T0.4** (incorporate the containers submodule) and is consumed by the build/CI
> story; do not treat a bare-host `go build` as a release artifact.

## Anti-bluff note (§11.4 / §11.4.6)

This scaffold deliberately contains **no business logic** and makes **no
capability claims**. Nothing here is "done" or "working" — it is a package
skeleton. Real implementations, their tests (all warranted types per §11.4.169),
paired §1.1 mutations, and captured data-plane evidence land phase by phase per
the plan. See the plan's Definition of Done.
