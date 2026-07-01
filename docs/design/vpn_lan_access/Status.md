# VPN-LAN Service Access — Integration Status

**Revision:** 3
**Last modified:** 2026-07-01T19:05:00Z
**Status:** In progress — ALL 13 phases (0–12) have committed deliverables on `main`. **Phase 12 bidirectional exposure** (operator mandate) is landed: design (`bidirectional_exposure.md`) + autonomous ingress-allowlist teeth (default-deny + narrow allowlist, `INGRESS_MUT` caught 3/3) + both-way reverse-leg assertions in all 5 protocol tests (NFS NLM/NSM callback, FTP active, Cast callback, adb reverse, email N/A). Autonomously PROVEN + wired into the standing suite as §11.4.135 guards: Phase-1 SSRF carve-out teeth, Phase-12 ingress teeth, and the autonomous battery (stress+chaos 100-iter, benchmark+memory, concurrency+load, DNS-rebinding-gap) — ALL GREEN. Phases 2/3/4/5/6/7/10/11 protocol/reflector/Cast/ADB/containerization/Challenge+HelixQA assets are AUTHORED + honest-SKIP-proven (bridge-down ⇒ SKIP + exit 0, zero fake PASS); every LIVE round-trip (both directions) is operator-gated on the svord connection. control-plane coverage raised (acl-helper 53.8% / cmd/api 61.1% / internal/redis 61.2% / cmd/healthd 70.3%, all -race clean). **⚠️ Data-plane env-block (operator-actionable, NOT a code defect):** host rootless-podman `aardvark-dns` cannot bind the netavark gateway `:53` → `:53128`/`:51080` don't serve + `./start` fails; the standing suite now honestly reports this (3 env FAILs) instead of hanging. Every claim below cites a real committed file/`qa-results/` artefact (§11.4.6); live paths honestly SKIP until the operator connects the bridge (§11.4.3) + repairs podman.
**Authority:** Inherits `constitution/Constitution.md` per §11.4.35. §11.4.45 integration-status doc for the VPN-LAN service-access feature workstream (`feature/vpn-aware-dynamic-routing`).
**Companion:** summary [`Status_Summary.md`](Status_Summary.md) · plan [`PLAN.md`](PLAN.md) · Miracast verdict [`miracast_verdict.md`](miracast_verdict.md) · operator guide [`../../guides/vpn_lan_bridge_setup.md`](../../guides/vpn_lan_bridge_setup.md)

## Operator-blocked / pending items (read first — §11.4.45 O(1) surface)

| Item | Why blocked / pending | Unblock condition |
|---|---|---|
| Live protocol round-trips (SMB/NFS/FTP/SFTP/WebDAV/email/Cast/ADB) | Need the live svord bridge connection — secrets + Mullvad WG + root/sudo on the bridge side (§11.4.21 / §11.4.10). The autonomous slate proves the honest-SKIP path + the anti-bluff gate now; the live round-trip evidence exists only when the bridge is genuinely up. | Operator copies `.env.example`→`.env`, points it at `svord_toolkit`, brings the VPN up; then each test emits real captured round-trip evidence. |
| Phase 5 discovery reflector — remote deploy | Deploying an Avahi/SSDP reflector changes a remote host (§11.4.122) — requires an interactive keep/deploy decision. Local reflector config + a local-stub discovery test are autonomous. | Operator authorizes the remote-side reflector deployment. |
| Phase 7 ADB flash (`usbip` fastboot) on real hardware | Flashing a real device is high-blast-radius (§11.4.133) — operator-gated. `adb connect`/`shell`/`getprop` over routed 5555 is autonomous once the bridge is up. | Operator authorizes the specific device flash. |

## Phase status matrix (captured-evidence-driven — §11.4.5/§11.4.69)

| Phase | Scope | Status | Evidence / commit |
|---|---|---|---|
| 0 | env-var svord bridge scaffold + svord-doctor preflight | PASS | `d781002`; svord-doctor 3-verdict discrimination (UP/SKIP/MISCONFIGURED) + standing-suite `test_vpn_lan_bridge` GREEN (honest SKIP + §11.4.115 teeth PASS, `qa-results/suite/run_20260701T160156Z.log` 71/64/7/0) `5c28f56` |
| 1 | L3 routed gateway + SSRF allowlist reconciliation | AUTHORED (local-stub GREEN) | `1d87b3a` `tests/vpn_lan/ssrf_carveout_teeth.sh`: proves the SOCKS SSRF floor survives the narrow 10/8 carve-out with NO live VPN + `sockd.conf` READ-ONLY — T1 live-floor teeth (metadata+loopback+all RFC1918 blocked, public passes), T2 narrow-carve floor-preserving, T3 ordering (first-match-wins); `SSRF_MUT=1` catches 2/2 golden-bad collapses (§11.4.107(10)); wired into standing suite `test_vpn_lan_ssrf`. Live 10/8 carve-out application stays bridge-gated + operator-gated (§11.4.101/§11.4.133) |
| 2 | SMB/CIFS/NMB + NFS round-trip | AUTHORED (SKIP-proven) | `182e80a` `tests/vpn_lan/smb_nfs_roundtrip.sh`; bridge-down SKIP + exit 0, PASS_lines=0 (no fake PASS); live sha256 round-trip operator-gated |
| 3 | FTP/FTPS/SFTP + WebDAV (WebDAV via existing Squid) | AUTHORED (SKIP-proven) | `182e80a` `tests/vpn_lan/ftp_sftp_webdav.sh`; wrong-answer⇒FAIL (WebDAV non-207 / SFTP sha-mismatch), unreachable⇒SKIP; live operator-gated |
| 4 | IMAP/IMAPS/SMTP-submission/POP3S + open-relay guard | AUTHORED (SKIP-proven) | `2f31460` `tests/vpn_lan/email_roundtrip.sh`; open-relay negative test (external-RCPT-accepted⇒FAIL); creds via stdin never argv (§11.4.10); live operator-gated |
| 5 | mDNS/SSDP/WS-Discovery/DNS-SD reflector | AUTHORED (SKIP-proven) | `d0b42df` `reflector_design.md` (Avahi enable-reflector + SSDP LOCATION-rewrite, cited RFC 6762/6763/5771/2365) + `tests/vpn_lan/discovery_reflect.sh` (bridge-down SKIP + exit 0, PASS_lines=0); remote deploy operator-gated (§11.4.122) |
| 6 | Chromecast / DIAL (reflect discovery + route control) | AUTHORED (SKIP-proven) | `65043ce` `tests/vpn_lan/chromecast_dial.sh`; eureka_info :8008 (200+JSON name⇒PASS, 200-no-name/non-200⇒FAIL fail-closed), CASTV2 :8009 liveness via status transition (identical⇒SKIP not fake-PASS §11.4.107); discovery = Phase-5 dependency; live operator-gated |
| 7 | ADB over VPN (access/debug/connect/flash) | AUTHORED (SKIP-proven) | `65043ce` `tests/vpn_lan/adb_over_vpn.sh`; routed 5555 connect+getprop⇒PASS, offline/unauthorized⇒FAIL; §11.4.174 device-safety (disconnect-our-serial-only, never kill-server); flash via `usbip` USB-bound operator-gated (§11.4.133); in-depth phased design in flight |
| 8 | Miracast structural-impossibility verdict | PASS (Won't-fix) | `12faf12` `miracast_verdict.md` (§11.4.112); cited Wi-Fi-Alliance evidence; Google Cast as the routable alternative; no fake traversal test |
| 9 | Documentation (operator bridge-setup guide) | PASS | `a5e5616` `../../guides/vpn_lan_bridge_setup.md` (routing map + verdict table + 12-row protocol matrix + FAQ); HTML+PDF §11.4.168 leak-clean |
| 10 | Containerization via containers submodule (§11.4.76) | AUTHORED (SKIP-proven) | `1911d5e` `containerization.md` + `vpn_lan_containers.yaml` (project-side service decl, config-injected §11.4.28) + `tests/vpn_lan/container_boot.sh` (bridge-down SKIP exit 0; malformed decl⇒FAIL fail-closed; never boots a container); `submodules/containers` untouched; remote deploy operator-gated (§11.4.122) |
| 11 | §11.4.169 full test-type coverage + Challenges + HelixQA | AUTHORED (mostly GREEN) | `89f73b7` `challenges/scripts/run_vpn_lan_challenges.sh` + HelixQA `tools/helixqa/banks/vpn_lan.yaml` (9 cases); autonomous test types LANDED + GREEN — stress+chaos (`97d9733`, 100-iter identical hash), benchmark+memory + DNS-rebinding gap (`4e2810c`), concurrency+load (`7e73b08`); HelixQA-run honestly blocked (6 un-vendored siblings + podman, §11.4.3) |
| 12 | Bidirectional exposure + ingress allowlist (operator mandate) | AUTHORED (GREEN + suite-wired) | `2ed0fed` `bidirectional_exposure.md` (return-route model + per-protocol both-way table + inverted-posture ingress = mirror of egress floor) + `tests/vpn_lan/ingress_allowlist_teeth.sh` (default-deny/exact-permit/host+port-narrow, `INGRESS_MUT` caught 3/3, PASS=4); `cc8b620` both-way reverse-leg assertions in all 5 protocol tests (NFS NLM/NSM, FTP active, Cast callback, adb reverse, email N/A §11.4.6); live both-way round-trip operator-gated |
| — | §11.4.135 standing regression guards (autonomous, no bridge/podman) | GREEN | `6d8893f` `test_vpn_lan_ssrf` + `test_vpn_lan_ingress` + `test_vpn_lan_autonomous_battery` wired into `run-tests.sh`; all rc=0 PASS≥1 FAIL=0 in the standing suite |

## Honest boundary (§11.4.6)

The feature's design + decoupled bridge + anti-bluff test scaffolding are proven now:
the Phase-0 bridge is GREEN in the standing suite with a genuine up↔down discrimination
(§11.4.115 teeth), and Phases 2/3/4 tests refuse to fake a PASS when the bridge is down
(bridge-down ⇒ honest SKIP, exit 0, zero `^PASS:` lines) — the anti-bluff gate is the
value delivered autonomously. Miracast is honestly classified structurally-impossible
(§11.4.112) with Google Cast as the routable alternative. The **live** protocol
round-trip evidence (real bytes, sha256, mailbox content, device serials) exists only
once the operator connects the svord bridge (secrets + Mullvad + root/sudo) — until then
those paths honestly SKIP (§11.4.3), never a fake PASS. No phase is "done" for the live
capability until its runtime signature verifies with captured evidence on a genuinely-up
bridge (§11.4.108) and it crosses the §11.4.169 test-type matrix. This doc is
§11.4.45-synced + §11.4.65-exported; it does not substitute for the §11.4.40 full-suite
retest before any release tag.
