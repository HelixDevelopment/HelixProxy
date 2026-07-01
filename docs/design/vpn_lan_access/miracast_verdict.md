# Miracast over the L3-Routed VPN — Structural-Impossibility Verdict

**Revision:** 1
**Last modified:** 2026-07-01T15:49:13Z
**Status:** Won't-fix — structurally-impossible (§11.4.112)
**Authority:** Inherits `constitution/Constitution.md` per §11.4.35. §11.4.112 structural-impossibility classification for the VPN-LAN service-access feature (Phase 8 of [`PLAN.md`](PLAN.md) §5).
**Feature workstream:** `feature/vpn-aware-dynamic-routing` (§11.4.167)
**Companion:** plan [`PLAN.md`](PLAN.md) §2 routing map + §5 Phase 8 · the positive casting capability is delivered by Phase 6 (Google Cast / DIAL).

---

## 1. Verdict statement

**Miracast CANNOT traverse the helix_proxy L3-routed VPN. This is a structural impossibility of the standard — Miracast lives below IP entirely — NOT a missing, unimplemented, or hard-to-build feature.** Per §11.4.112 the item is classified **`Won't-fix: structurally-impossible`** with the cited authoritative evidence recorded in §4 below. This is a durable verdict (not eternal): it is overturned only by NEW evidence that the platform constraint itself changed (§5), never by re-deriving the same impossibility.

Miracast is therefore **out of scope by physics** for the routed-VPN traversal, exactly as recorded in [`PLAN.md`](PLAN.md) §2 (the "L2 / Wi-Fi-Direct" traffic class → **STRUCTURALLY-IMPOSSIBLE over L3 VPN**). The routable "cast to a remote display" capability the operator wants is delivered instead by **Google Cast / DIAL** (Phase 6), which is IP-based and works over the VPN with a remote-side discovery reflector (§3).

---

## 2. What Miracast actually is (FACT, §11.4.6)

Miracast is a **Wi-Fi Alliance** certification program for wireless display, branded **Wi-Fi CERTIFIED Miracast**. It certifies the underlying **Wi-Fi Display** technical specification. Its defining architectural property (FACT):

- Miracast is a **peer-to-peer** wireless-display connection between a **source** (e.g. a phone/laptop) and a **sink** (e.g. a TV/receiver/dongle).
- Its transport substrate is **Wi-Fi Direct** (Wi-Fi Peer-to-Peer, built on IEEE 802.11). The two devices form a **P2P group** by negotiating directly over the radio — one device becomes the **Group Owner** (acting as a soft access point), the other joins as a P2P client — **with no network infrastructure, no wireless access point, and no router between them.**
- Group formation happens at the **link layer (Layer 2)** via 802.11 P2P discovery + Group-Owner negotiation over the air, between two devices in **radio (RF) proximity**. Miracast then negotiates an RTSP session and streams H.264 video (RTP) **inside that direct P2P group**.

**Honest nuance (FACT, not a contradiction):** within the Wi-Fi Direct group, the Group Owner does run DHCP and the RTSP/RTP session does ride an IP link. But that IP link **exists only on the direct radio association between the two physically co-located devices** — it is a private, self-contained P2P group created by the 802.11 radios, **not** an infrastructure/routed network. There is no routable IP hop between the source and the sink for an external network to insert itself into; the source and the sink **are** the network.

---

## 3. WHY it cannot traverse an L3 VPN (the L2-vs-IP-routing argument, FACT)

The helix_proxy VPN is **L3-routed** (WireGuard + L2TP/PPP over `ppp0`; reachable subnet `10.0.0.0/8`; svord host `10.6.100.221`) — see [`PLAN.md`](PLAN.md) §2. A Layer-3 VPN does exactly one thing: it **routes IP packets** between IP subnets that are already reachable by IP routing. Everything helix_proxy can carry (SMB, NFS, FTP, SFTP, IMAP, SMTP, POP3, WebDAV, Cast control, DIAL, ADB) is a **unicast IP** service — an IP endpoint the router can forward a packet toward.

Miracast has **no such IP hop to route.** Its substrate is a Wi-Fi Direct P2P radio association negotiated **directly between two devices in RF proximity** at the link layer. The mismatch is categorical:

| Layer | Miracast requires | What an L3 VPN provides |
|---|---|---|
| L1/L2 (radio) | A direct 802.11 Wi-Fi Direct P2P group formed by the two devices' radios in RF proximity | **Nothing** — a VPN does not create radio associations |
| L2 group formation | P2P discovery + Group-Owner negotiation over the air | **Nothing** — cannot be synthesized across a tunnel |
| L3 (IP) | A private IP link confined **inside** the P2P group | Routes IP packets **between already-reachable subnets** — but there is no inter-subnet IP hop in Miracast to route |

To "route Miracast over the VPN" the VPN would have to **manufacture a Wi-Fi Direct radio association between a source and a sink that are not in RF proximity** — i.e. create a physical-layer 802.11 P2P group across a routed tunnel. A VPN cannot do this; nothing at Layer 3 can. The source and sink must be the same radio group, and radio proximity is a physical precondition the tunnel cannot supply. **Therefore Miracast traversal over the L3 VPN is structurally impossible — the impossibility is at the standard's physical/link substrate, below IP, where the VPN has no reach.**

This is the recon-5 FACT recorded in [`PLAN.md`](PLAN.md) §11: *"Miracast = Wi-Fi-Direct/L2 structurally-impossible."*

---

## 4. Cited authoritative evidence (§11.4.112 + §11.4.99 latest-source)

The verdict rests on the published standard, not inference. Authoritative sources (access date **2026-07-01**):

1. **Wi-Fi Alliance — Wi-Fi CERTIFIED Miracast** (the certifying body's own definition): Miracast is a peer-to-peer wireless-display standard built on **Wi-Fi Direct**, establishing a direct device-to-device connection **without an access point / network infrastructure**.
   `https://www.wi-fi.org/discover-wi-fi/miracast`

2. **Wikipedia — Miracast** (technical overview + references to the Wi-Fi Display spec): Miracast forms a connection over **Wi-Fi Direct**; source and sink negotiate a **peer-to-peer** link; it is a screen-mirroring standard operating over a direct P2P association rather than an infrastructure network.
   `https://en.wikipedia.org/wiki/Miracast`

3. **Wikipedia — Wi-Fi Direct** (the P2P substrate): Wi-Fi Direct (Wi-Fi Peer-to-Peer) lets devices connect **directly, without a wireless access point / router**; one device acts as a **Group Owner** functioning as a soft AP — a **link-layer** association negotiated by the devices themselves.
   `https://en.wikipedia.org/wiki/Wi-Fi_Direct`

4. **Devopedia — Wi-Fi Direct** (independent technical corroboration): Wi-Fi Direct forms a **P2P group** via Group-Owner negotiation over 802.11, an infrastructure-less direct radio link between devices in proximity.
   `https://devopedia.org/wi-fi-direct`

Together these establish, as FACT, that Miracast's transport is a Wi-Fi Direct **Layer-2 radio P2P group with no infrastructure/routed IP hop** — the precise property that makes L3-VPN traversal structurally impossible (§3).

---

## 5. Honest boundary + what IS possible instead (§11.4.6 / §11.4.112)

**What this verdict does and does not claim.** It claims — with cited evidence — that **routing/tunneling the Miracast protocol itself across the L3 VPN is impossible by the standard's design.** It does **not** claim "casting to a remote display is impossible." A routable capability exists and is delivered elsewhere in this feature:

- **Google Cast / DIAL (Phase 6) — the routable drop-in alternative.** Google Cast (CASTV2 control on `8008`/`8009`) and DIAL are **IP-based** application protocols. Their control planes route over the VPN as ordinary unicast TCP; only their **discovery** (mDNS `_googlecast._tcp` / SSDP `M-SEARCH`) is multicast and needs a **remote-side reflector** (Phase 5), because routers do not forward multicast across L3. This is the correct "cast to a remote display" path over the VPN — see [`PLAN.md`](PLAN.md) §2 (Cast control routes; discovery reflects) and §5 Phase 6.

- **Remote-site Miracast receiver (driven by something the VPN CAN reach).** Miracast can still be used **locally at the remote site**: a Miracast sink physically co-located with a remote source forms its Wi-Fi Direct group locally (in RF proximity, as the standard requires), and helix_proxy reaches whatever **IP-based** control/orchestration drives that remote setup — never the Wi-Fi Direct radio link itself. The VPN carries the routable control; the Miracast radio association stays local to the remote site where physics allows it.

**No fake traversal test exists or will be authored.** Per Phase 8 (T8.2) the cited spec text in §4 **is** the artifact for this verdict; the positive, evidence-backed casting capability lives in Phase 6. Authoring a "Miracast-over-VPN" test that appears to pass would be a §11.4 / §11.4.107 bluff — there is nothing real to route, so any green result would be fabricated. The correct posture is this documented structural verdict + the Phase-6 routable alternative.

---

## 6. Reopen condition (§11.4.34 / §11.4.7 / §11.4.112)

This verdict is **durable but not eternal.** It may be reopened **only** on captured **NEW evidence that the platform constraint itself changed** — for example: a future Wi-Fi Alliance revision defining an infrastructure/routed Miracast transport; a standardized IP-tunneled Wi-Fi Display mode; or an OS/driver mechanism that presents a Miracast sink over routable IP rather than a Wi-Fi Direct radio group. A reopen MUST cite that new authoritative evidence per §11.4.7 (demotion requires positive evidence captured under the changed conditions) and §11.4.34 (reopen attribution). **Re-deriving the same impossibility from the same unchanged standard is NOT a valid reopen** (§11.4.112) — it merely repeats settled work. Until such new evidence exists, the classification stands and Miracast traversal is not re-attempted.

---

## Sources verified 2026-07-01

- Wi-Fi Alliance — Wi-Fi CERTIFIED Miracast: `https://www.wi-fi.org/discover-wi-fi/miracast`
- Wikipedia — Miracast: `https://en.wikipedia.org/wiki/Miracast`
- Wikipedia — Wi-Fi Direct: `https://en.wikipedia.org/wiki/Wi-Fi_Direct`
- Devopedia — Wi-Fi Direct: `https://devopedia.org/wi-fi-direct`

*Access date for all sources: 2026-07-01. Verdict basis: the Wi-Fi Alliance Miracast standard is built on Wi-Fi Direct (Wi-Fi Peer-to-Peer, IEEE 802.11) — a link-layer, infrastructure-less, radio-proximity P2P association with no routable IP hop for an L3 VPN to carry (§3, FACT §11.4.6). Classification `Won't-fix: structurally-impossible` per §11.4.112.*
