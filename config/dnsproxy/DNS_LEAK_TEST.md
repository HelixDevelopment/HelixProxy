# DNS-leak test — DESIGN (owed to T7.1 / "P10", needs the live tunnel)

**Revision:** 1
**Last modified:** 2026-06-30T21:40:00Z
**Status:** DESIGN ONLY — NOT RUN. This is the data-plane anti-leak proof for
the per-tunnel dnsproxy forwarder. It requires a **live gluetun tunnel +
in-netns dnsproxy** (the per-netns wiring from `README.md`), which does not
exist until the live-tunnel wiring phase (plan **T7.1** / Phase 7; the parent's
**"P10"**). Per §11.4.6 nothing here is a passing result yet — it is the
**designed** probe that will produce the proof later.

## Goal (the claim this proves)

With the tunnel up, a name resolved *through the proxy stack* MUST show:

1. **ZERO plaintext DNS on the real uplink** — no UDP/TCP port-53 packets to
   any address on the host's physical interface (the leak that would expose the
   user's queries to their ISP).
2. **All DNS as encrypted DoT/DoH to the configured upstream, inside the
   tunnel** — captured *in the gluetun netns* as TLS (DoT :853 / DoH :443) to
   `1.1.1.1`, egressing via the WireGuard interface.

This is the §11.4.69 `network_connectivity` / DNS-leak evidence class and maps
to the spec §13 `no_leak/killswitch` row ("DNS only via intended resolver") and
`DYNAMIC_ROUTING.md` §5 fail-closed-never-leak. **Captured packets are the
evidence — config alone is not** (§11.4.123 / §11.4.5).

## Preconditions (all owed to T7.1 / "P10")

- A gluetun container up for a profile, WireGuard handshake fresh
  (`wg show` / gluetun control API), `vpn:status:<profile>` = up.
- One `dnsproxy` instance running **inside that gluetun netns** with
  `config/dnsproxy/dnsproxy.yaml` (loopback `127.0.0.1:53`, DoT upstream).
- Squid/Dante in the same netns resolving via `127.0.0.1`.
- `tcpdump`/`tshark` available in the netns (or via `podman run` joining that
  netns — rootless; §11.4.161). Identify the **real uplink** iface and the
  **WireGuard** iface (e.g. `wg0`) up front so the captures target the right
  interfaces (§11.4.111 resolve-by-name, not a guessed index).

## Procedure (designed)

> Run all captures **inside the gluetun netns** (join it; do not capture on the
> host's default netns where the tunnel's traffic is already encapsulated). Use
> the project's existing tunnel + per-netns dnsproxy — do **not** touch the
> operator's `wg0-mullvad` / `lava-*` resources (§11.4.174).

1. **Pick a fresh, uncached name** (e.g. a random label under a domain you
   control or a low-TTL public name) so the answer is not served from
   dnsproxy's cache (cache HIT would emit no upstream packet and falsely look
   leak-free). Optionally flush the dnsproxy cache / restart it first.

2. **Start two captures in the netns, simultaneously:**
   - **A — real uplink, port 53 (the leak detector):**
     `tcpdump -ni <uplink_iface> -w qa-results/<run-id>/uplink_port53.pcap 'port 53'`
     EXPECT: **zero packets** for the whole window.
   - **B — WireGuard iface, encrypted DNS (the positive proof):**
     `tcpdump -ni <wg_iface> -w qa-results/<run-id>/wg_dns.pcap 'port 853 or port 443 or host 1.1.1.1'`
     EXPECT: TLS to `1.1.1.1` (DoT :853, or :443 if DoH) during the window.

3. **Drive a resolution through the stack** (the realistic path, not a raw dig
   at the upstream): e.g. `curl -x http://<squid>:53128 http://<fresh-name>/`
   or a `dig @127.0.0.1 <fresh-name>` from inside the netns. Capture stdout +
   exit so the run is reproducible (§11.4.123).

4. **Stop captures. Analyze with content verification (not packet-count alone):**
   - **Leak gate (A):** `tcpdump -nr uplink_port53.pcap | wc -l` MUST be `0`.
     Any packet here = **FAIL** (a real DNS leak). Pinpoint offenders with
     `tcpdump -nr uplink_port53.pcap` (src/dst/port) for the §11.4.138 bluff
     audit if one appears.
   - **Encryption gate (B):** `tshark -r wg_dns.pcap -Y 'tls.handshake'` MUST
     show a TLS handshake to `1.1.1.1` (DoT/DoH). Confirms DNS was encrypted +
     tunnel-routed, not merely "absent on the uplink".
   - **Cross-check:** the resolved name appears in dnsproxy's verbose log as
     served by `tls://1.1.1.1` (set `verbose: true` for the run).

5. **Anti-stickiness / negative control (kill-switch alignment):** bring the
   tunnel **down**, repeat step 3, and assert the stack returns a fail-closed
   503 (spec §13 `graceful_503`) and STILL emits **zero** plaintext `:53` on
   the uplink — i.e. it does not fall through to a leaking direct query
   (`DYNAMIC_ROUTING.md` §5). This is the "never leak even when down" half.

## PASS / FAIL (designed verdict)

| Gate | PASS | FAIL |
|---|---|---|
| Uplink :53 (tunnel up) | 0 packets | ≥1 packet → DNS leak |
| WG DoT/DoH (tunnel up) | TLS handshake to `1.1.1.1` present | no encrypted DNS to upstream |
| Tunnel down | fail-closed 503 + still 0 uplink :53 | direct/leaking query |

A green run is recorded via `ab_pass_with_evidence` (spec §14 evidence harness)
citing the two `.pcap` paths + the tshark/tcpdump analysis under
`qa-results/<run-id>/` (raw) and curated under `docs/qa/<run-id>/` (§11.4.83).
Paired §1.1 mutation (per the plan): point the upstream at a plain `udp://`
resolver (or drop dnsproxy so the client resolves directly) → the leak gate
MUST FAIL → confirms the test genuinely catches a leak (not a bluff gate).

## Honest boundary (§11.4.6)

This document is the **design** of the proof. It asserts nothing about the
current state. The proof is produced only when the live per-netns tunnel +
dnsproxy wiring exists (T7.1 / "P10"). Until those `.pcap` artifacts are
captured and analyzed, DNS privacy / no-leak for helix_proxy is **unproven**.
