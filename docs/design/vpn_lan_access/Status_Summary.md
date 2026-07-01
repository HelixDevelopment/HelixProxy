# VPN-LAN Service Access — Status Summary

**Revision:** 3
**Last modified:** 2026-07-01T19:05:00Z
**Status:** Companion summary of [`Status.md`](Status.md) (§11.4.56 two-audience).

---

## Page 1 — For the operator / stakeholders (plain language)

We are building helix_proxy's ability to **reach and use the services on the far side of
the VPN** — file shares, file transfer, email, casting, and Android devices. The design is
finished and security-checked, and the plumbing that connects to the VPN (via your existing
`svord_toolkit` scripts) is built and proven.

**What's done and proven right now (without needing the live VPN):**

- **The bridge connector** — helix_proxy reads where your `svord_toolkit` scripts live from a
  private settings file, checks whether the VPN is up with a "doctor" tool, and — crucially —
  when the VPN is **down** it **honestly reports "skipped," never a fake success.** The test
  suite confirms this and also proves the check has real teeth (a healthy stub flips it to
  "up"). This is the guarantee that we never pretend a feature works when it doesn't.
- **The protocol tests** — the file-share (SMB/NFS), file-transfer (FTP/SFTP/WebDAV), and
  email tests are written and self-proven: each writes and reads back real data (checked
  byte-for-byte) when the VPN is up, and the email test includes a **spam-relay safety check**
  that would fail helix_proxy if it ever accepted unauthenticated mail. When the VPN is down,
  they all skip honestly.
- **Miracast** is honestly marked **impossible** over this kind of VPN (it's a direct radio
  link, not an internet protocol) — with **Chromecast** offered as the working alternative.
- **The operator guide** is written (setup steps, protocol table, FAQ).

**What needs you (clearly flagged, we will ask before acting):** the **live VPN connection**
(your secrets + Mullvad + admin rights) unlocks the real end-to-end tests; deploying the
device-**discovery helper** on a remote machine, and **flashing** any real device, each need
your go-ahead first — we never change `svord_toolkit` or a remote host without asking.

**Bottom line:** the feature is designed, the anti-bluff plumbing is built and proven, and
the live parts switch on the moment you connect the VPN. Nothing is faked; skipped means
skipped.

---

## Page 2 — For software engineers

L3-routed VPN ⇒ route unicast / proxy HTTP-shaped via Squid / reflect multicast / L2
structurally-impossible. Env-var bridge (§11.4.28), honest-SKIP gate (`bridge_require` rc 2
OPERATOR-BLOCKED §11.4.68), anti-bluff `ab_pass_with_evidence` (non-empty artefact required).

| Phase | Scope | Status | Commit / evidence |
|---|---|---|---|
| 0 | bridge scaffold + svord-doctor | PASS | `d781002` + suite `test_vpn_lan_bridge` GREEN (§11.4.115 teeth) `5c28f56` |
| 1 | routed gateway + SSRF reconciliation | AUTHORED (local-stub GREEN) | `1d87b3a` ssrf_carveout_teeth.sh: floor survives narrow carve (T1/T2/T3), `SSRF_MUT=1` catches 2/2 collapses; wired into standing suite; live carve bridge+operator-gated (§11.4.120/§11.4.133) |
| 2 | SMB/CIFS/NMB + NFS | AUTHORED (SKIP-proven) | `182e80a` sha256 round-trip; bridge-down PASS_lines=0 |
| 3 | FTP/FTPS/SFTP + WebDAV(via Squid) | AUTHORED (SKIP-proven) | `182e80a` wrong-answer⇒FAIL |
| 4 | IMAP/SMTP-submission/POP3 + open-relay guard | AUTHORED (SKIP-proven) | `2f31460` external-RCPT-accepted⇒FAIL |
| 5 | mDNS/SSDP/WS-Disc/DNS-SD reflector | AUTHORED (SKIP-proven) | `d0b42df` reflector_design.md (cited RFCs) + discovery_reflect.sh; remote deploy operator-gated (§11.4.122) |
| 6 | Chromecast/DIAL | AUTHORED (SKIP-proven) | `65043ce` chromecast_dial.sh; eureka 8008 + CASTV2 8009 transition (§11.4.107); discovery = Phase-5 dep |
| 7 | ADB (access/debug/connect/flash) | AUTHORED (SKIP-proven) | `65043ce` adb_over_vpn.sh; routed 5555 + §11.4.174 serial-safety; usbip flash operator-gated (§11.4.133) |
| 8 | Miracast | PASS (Won't-fix, §11.4.112) | `12faf12` cited verdict + Cast alternative |
| 9 | operator bridge-setup guide | PASS | `a5e5616` leak-clean HTML+PDF |
| 10 | containerize (§11.4.76) | AUTHORED (SKIP-proven) | `1911d5e` containerization.md + vpn_lan_containers.yaml + container_boot.sh; submodule untouched |
| 11 | §11.4.169 coverage + Challenges + HelixQA | AUTHORED (mostly GREEN) | `89f73b7` Challenge + 9-case bank; autonomous types GREEN — stress+chaos `97d9733`, bench+memory + dns-rebinding `4e2810c`, concurrency+load `7e73b08`; HelixQA-run blocked 6 siblings+podman (§11.4.3) |
| 12 | Bidirectional exposure + ingress allowlist | AUTHORED (GREEN + suite-wired) | `2ed0fed` bidirectional_exposure.md + ingress_allowlist_teeth.sh (`INGRESS_MUT` 3/3, PASS=4); `cc8b620` both-way reverse-leg in all 5 protocol tests; live both-way operator-gated |
| — | §11.4.135 autonomous suite guards | GREEN | `6d8893f` test_vpn_lan_ssrf + test_vpn_lan_ingress + test_vpn_lan_autonomous_battery wired, all rc=0 PASS≥1 |

Autonomous value delivered: the anti-bluff gate (bridge-down ⇒ honest SKIP, exit 0, zero
`^PASS:`) + the §11.4.115 teeth in the standing suite. Live round-trip evidence
(bytes/sha256/mailbox/serials) is operator-gated on the svord connection. Composes
§11.4.3/§11.4.28/§11.4.45/§11.4.68/§11.4.69/§11.4.108/§11.4.112/§11.4.115/§11.4.120/
§11.4.122/§11.4.133/§11.4.167/§11.4.169.
