# VPN‑Aware Proxy Extension – Architecture & Research

## Overview
The extension enables the existing Proxy to forward traffic to hosts accessible only via VPN, without any interruption when VPN tunnels are toggled on/off.

## Core Components
1. **VPN Manager** – handles WireGuard/OpenVPN tunnels, publishes state to Redis.
2. **Proxy Core** – Gin‑based reverse proxy that consults DB and Redis before forwarding.
3. **PostgreSQL** – persistent store for VPN profiles, target hosts, proxy rules.
4. **Redis** – real‑time tunnel status cache and event bus.
5. **Docker / Kubernetes** – host networking allows pods to use host VPN routes.

## Scalability
- DaemonSet VPN clients on every Kubernetes node create tunnels.
- Proxy pods use `hostNetwork: true` and share the node’s routing table.
- Stateless proxy can be scaled horizontally; no single point of failure.

## Sequence: VPN Toggle
1. VPN Manager detects tunnel state change, updates Redis key + publishes event.
2. Proxy subscriber immediately picks up the change.
3. Requests that require that tunnel check the key and receive an immediate 503 if down, or succeed if up – no crash, no restart.
