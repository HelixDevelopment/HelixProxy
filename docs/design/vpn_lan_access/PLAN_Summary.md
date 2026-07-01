# VPN-LAN Service Access — Plan Summary

**Revision:** 2
**Last modified:** 2026-07-01T17:05:00Z
**Status:** Companion summary of [`PLAN.md`](PLAN.md) (§11.4.56 two-audience). Rev 2 adds the operator's **bidirectional** mandate (2026-07-01): exposure must work fully **both ways** (VPN hosts can also reach exposed proxy-side services — needed by FTP active, NFS lock callbacks, Cast callbacks, `adb reverse`, etc.), governed by a **default-deny + allowlist** ingress surface (the mirror of the egress SSRF floor) and covered by all supported test types — see Phase 12 + `bidirectional_exposure.md`.

---

## Page 1 — For the operator / stakeholders (plain language)

We are building the ability for helix_proxy to reach and use **all the mainstream
services running on the far side of the VPN** — file shares (Windows/SMB and Unix/NFS),
file transfer (FTP, SFTP, WebDAV), email (IMAP/SMTP/POP3), device discovery (Bonjour,
UPnP), casting (Chromecast), and Android devices over ADB (including flashing). The VPN
connection itself is driven by your existing `svord_toolkit` scripts — but helix_proxy
never hardcodes them: it reads the script location from a setting you provide in a private
`.env` file (a tracked `.env.example` shows exactly how to point it at `svord_toolkit`).

**How it works, in one sentence:** normal one-to-one services (files, email, ADB) are
simply *routed* over the VPN; web-style services (WebDAV) already work through the existing
proxy; device *discovery* (which uses network-wide "shout" messages that don't cross the
VPN) needs a small helper deployed on the far side; and one thing — **Miracast** — is
**physically impossible** over this kind of VPN (it's a direct radio link, not an internet
protocol), so we honestly say so and offer **Chromecast** as the working alternative.

**What we will prove, with saved evidence, no faking:** every protocol gets a real
round-trip test (write a file and read it back byte-for-byte, list a real mailbox, connect
to a real Android device). When the live VPN isn't connected (which needs your credentials),
the tests **honestly skip** instead of pretending to pass.

**What needs you (parked until you decide):** the live VPN connection (secrets + Mullvad +
admin rights), deploying the discovery helper on a remote host, and flashing any real
device — each of these we will **ask you about with clear options** before doing anything,
and we will **never** change `svord_toolkit` or any remote host without asking first.

**Bottom line:** the full architecture is designed and security-checked; we can build and
prove all the "logic" parts autonomously right now, and the "live" parts switch on the
moment you provide the VPN connection. Nothing is overstated, nothing is faked.

---

## Page 2 — For software engineers

L3-routed VPN (WireGuard+L2TP/PPP, `10.0.0.0/8`, svord host `10.6.100.221`) ⇒ **route
unicast, proxy HTTP-shaped, reflect multicast, structurally-reject L2**. Bridge is
env-var-decoupled (§11.4.28): `HELIX_SVORD_DIR` / `HELIX_BRIDGE_{CONNECT,DISCONNECT,HEALTH}`
/ `HELIX_BRIDGE_{SUBNET,HOST}`, real values in gitignored `.env`, shape in tracked
`.env.example` (§11.4.30/§11.4.77). SSRF reconciliation (§11.4.120): keep RFC1918/metadata
floor, add narrow `HELIX_BRIDGE_SUBNET` carve-out (Dante first-match above internal-deny),
S1/S3/S4 guards stay GREEN + paired §1.1 teeth; open-relay guard on email (§4.3).

| Phase | Scope | Primitive | Autonomous now? |
|---|---|---|---|
| 0 | Bridge scaffold + `svord-doctor` preflight | env-var contract + honest SKIP | **YES** |
| 1 | L3 routed gateway + SSRF allowlist reconciliation | route + Dante/Squid carve-out | logic YES (local stub) |
| 2 | SMB/CIFS/NMB + NFS | route (mount round-trip + sha256) | live-gated |
| 3 | FTP/FTPS/SFTP + WebDAV | route + passive range; WebDAV via Squid | live-gated (WebDAV logic YES) |
| 4 | IMAP/IMAPS/SMTP-submission/POP3S | route/CONNECT + open-relay guard | live-gated |
| 5 | mDNS/SSDP/WS-Discovery/DNS-SD reflector | remote-side reflector (containers §11.4.76) | operator-gated deploy |
| 6 | Chromecast/DIAL | reflect discovery + route control (8008/8009) | live-gated |
| 7 | ADB (access/debug/connect/flash) | route 5555 + adb server + `usbip` fastboot | live+device-gated |
| 8 | Miracast | **structurally-impossible §11.4.112** + Cast alt | **YES (verdict)** |
| 9/10/11 | docs / containerize / §11.4.169 full test-type coverage + Challenges + HelixQA | — | continuous |

Critical path: Phase 0 → Phase 1 (routed gateway + reconciled SSRF) gates all unicast;
Phase 5 → Phase 6 for Cast; Phase 8 independent. Evidence under
`qa-results/vpn_lan/<phase>/<ts>/`; bridge-down ⇒ §11.4.3 honest SKIP (never fail-open,
§11.4.69). Deep-research citations §11 (§11.4.150). Composes §11.4.28/§11.4.58/§11.4.66/
§11.4.76/§11.4.101/§11.4.112/§11.4.115/§11.4.120/§11.4.122/§11.4.133/§11.4.167/§11.4.169.
