# VPN-LAN Service Access — Integration Status

**Revision:** 2
**Last modified:** 2026-07-01T16:48:00Z
**Status:** In progress — ALL 12 phases (0–11) now have committed deliverables. Phase 0 (bridge scaffold) + Phase 1 (SSRF carve-out teeth, local-stub GREEN + wired into the standing suite) + Phase 8 (Miracast Won't-fix) + Phase 9 (docs) are autonomously PROVEN; Phases 2/3/4/5/6/7/10/11 protocol + reflector + Cast + ADB + containerization + Challenge/HelixQA assets are AUTHORED and honest-SKIP-proven (bridge-down ⇒ SKIP + exit 0, zero fake PASS); every live round-trip is operator-gated on the svord connection. Every claim below cites a real committed file/`qa-results/` artefact (§11.4.6); every live path honestly SKIPs until the operator connects the bridge (§11.4.3).
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
| 11 | §11.4.169 full test-type coverage + Challenges + HelixQA | AUTHORED (run-blocked) | `89f73b7` `challenges/scripts/run_vpn_lan_challenges.sh` + HelixQA `tools/helixqa/banks/vpn_lan.yaml` (9 cases); bridge-down self-proof RESULT:OK PASS=0 FAIL=0 all-SKIP; HelixQA-run honestly blocked (6 un-vendored siblings, §11.4.3); stress+chaos §11.4.85 in flight |

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
