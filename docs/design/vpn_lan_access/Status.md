# VPN-LAN Service Access — Integration Status

**Revision:** 1
**Last modified:** 2026-07-01T16:35:00Z
**Status:** In progress — Phase 0 (bridge scaffold) + Phase 8 (Miracast verdict) + Phase 9 (docs) DONE; Phases 2/3/4 protocol tests authored + honest-SKIP-proven (live round-trips operator-gated); Phases 5/6/7/10/11 in progress. Every autonomous claim below cites a real `qa-results/` artefact or a committed file (§11.4.6); every live-round-trip path honestly SKIPs until the operator connects the svord bridge (§11.4.3).
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
| 1 | L3 routed gateway + SSRF allowlist reconciliation | PENDING | Design in `PLAN.md` §4; security-critical, conductor-owned; local-stub SSRF-teeth logic to land before any live 10/8 carve-out (gated on bridge up) |
| 2 | SMB/CIFS/NMB + NFS round-trip | AUTHORED (SKIP-proven) | `182e80a` `tests/vpn_lan/smb_nfs_roundtrip.sh`; bridge-down SKIP + exit 0, PASS_lines=0 (no fake PASS); live sha256 round-trip operator-gated |
| 3 | FTP/FTPS/SFTP + WebDAV (WebDAV via existing Squid) | AUTHORED (SKIP-proven) | `182e80a` `tests/vpn_lan/ftp_sftp_webdav.sh`; wrong-answer⇒FAIL (WebDAV non-207 / SFTP sha-mismatch), unreachable⇒SKIP; live operator-gated |
| 4 | IMAP/IMAPS/SMTP-submission/POP3S + open-relay guard | AUTHORED (SKIP-proven) | `2f31460` `tests/vpn_lan/email_roundtrip.sh`; open-relay negative test (external-RCPT-accepted⇒FAIL); creds via stdin never argv (§11.4.10); live operator-gated |
| 5 | mDNS/SSDP/WS-Discovery/DNS-SD reflector | IN PROGRESS | Remote deploy operator-gated (§11.4.122); reflector design + local-stub discovery test in flight |
| 6 | Chromecast / DIAL (reflect discovery + route control) | IN PROGRESS | `tests/vpn_lan/chromecast_dial.sh` authoring in flight; control 8008/8009 routes, discovery via Phase-5 reflector |
| 7 | ADB over VPN (access/debug/connect/flash) | IN PROGRESS | `tests/vpn_lan/adb_over_vpn.sh` authoring in flight; routed 5555 + adb-server; flash via `usbip` (USB-bound, operator-gated §11.4.133) |
| 8 | Miracast structural-impossibility verdict | PASS (Won't-fix) | `12faf12` `miracast_verdict.md` (§11.4.112); cited Wi-Fi-Alliance evidence; Google Cast as the routable alternative; no fake traversal test |
| 9 | Documentation (operator bridge-setup guide) | PASS | `a5e5616` `../../guides/vpn_lan_bridge_setup.md` (routing map + verdict table + 12-row protocol matrix + FAQ); HTML+PDF §11.4.168 leak-clean |
| 10 | Containerization via containers submodule (§11.4.76) | PENDING | Reflector + adb-server to boot on-demand via `submodules/containers` (rootless §11.4.161); depends on Phase 5/6/7 design |
| 11 | §11.4.169 full test-type coverage + Challenges + HelixQA | IN PROGRESS | Challenge script + HelixQA `vpn_lan.yaml` bank authoring in flight; HelixQA-run honestly blocked (6 un-vendored siblings, §11.4.3) |

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
