// liveness.go — the FRESH per-poll through-tunnel liveness probe (D3 core fix;
// §11.4.68 fail-closed gate, §11.4.107 liveness, §11.4.111 name-not-index).
//
// WHY this signal (cited: gluetun v3.40 docs / wiki):
//   - gluetun's control API /v1/publicip/ip is a CACHED value (served from
//     /tmp/gluetun/ip, refreshed only on the health-check cadence — 30 min when
//     healthy, 60 s on failure), so it is NOT a fresh per-poll egress proof; and
//     the control API exposes NO WireGuard transfer/handshake counters at all
//     (route list: GET /v1/vpn/status, /v1/vpn/settings, /v1/portforward,
//     /v1/dns/status, /v1/updater/status, /v1/publicip/ip — none carry rx/tx or
//     handshake). healthd, on the bridge net and not in gluetun's netns, has no
//     `wg` binary and no reachable :9999 internal health server.
//   - gluetun's BUILT-IN HTTP forward proxy (HTTPPROXY=on, default :8888) runs
//     INSIDE the tunnel netns and forwards through the active tun0 interface
//     behind the kill-switch (FIREWALL=on). squid already cache_peers it. A GET
//     issued THROUGH that proxy to an external IP-echo therefore either egresses
//     via the LIVE tunnel and returns (fresh liveness confirmed THIS poll) or is
//     blocked by the kill-switch / times out when the tunnel is down (⇒ error ⇒
//     fail-closed). That is a genuine fresh data-plane proof, not a cached read.
//
// Stdlib only (net/http + net/url). Credentials (§11.4.10): the proxy URL MAY
// embed user:pass (gluetun HTTPPROXY_USER/HTTPPROXY_PASSWORD); it is sourced from
// an env var / secret file by the caller, never hardcoded and never logged.
package vpn

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// DefaultLivenessTarget is the external IP-echo GETd through the tunnel proxy. It
// is deliberately a plain, cache-defeating text endpoint; the operator may override.
const DefaultLivenessTarget = "https://ipinfo.io/ip"

// TunnelProxyProber issues a real HTTP GET to Target THROUGH an HTTP forward proxy
// (gluetun's built-in :8888). A 2xx with a non-empty body ⇒ the tunnel carried
// traffic THIS poll. Any transport error (kill-switch block, timeout, DNS fail),
// non-2xx status, or empty body ⇒ error ⇒ the caller fails closed. It satisfies
// LivenessProber.
type TunnelProxyProber struct {
	// Target is the external URL fetched through the tunnel (an IP-echo endpoint).
	Target string
	// HTTP is the client whose Transport routes via the tunnel proxy.
	HTTP *http.Client
}

// NewTunnelProxyProber builds a prober that routes GET target through proxyURL
// (e.g. "http://proxy-gluetun:8888" or, with auth, "http://user:pass@host:8888").
// A blank target falls back to DefaultLivenessTarget. timeout bounds each probe
// (a tunnel-down probe MUST NOT hang the poll); a non-positive timeout defaults to
// 4s. An unparseable proxyURL is an error (the caller then disables the probe and
// logs — it never silently treats a bad URL as a passing probe).
func NewTunnelProxyProber(proxyURL, target string, timeout time.Duration) (*TunnelProxyProber, error) {
	// NOTE (§11.4.10): the proxy URL MAY carry credentials, so it is NEVER echoed
	// in an error — url.Parse's own error would include the raw URL, so it is
	// replaced with a credential-free message.
	pu, err := url.Parse(proxyURL)
	if err != nil {
		return nil, fmt.Errorf("liveness: proxy URL is unparseable")
	}
	if pu.Host == "" {
		return nil, fmt.Errorf("liveness: proxy URL has no host")
	}
	if target == "" {
		target = DefaultLivenessTarget
	}
	if timeout <= 0 {
		timeout = 4 * time.Second
	}
	return &TunnelProxyProber{
		Target: target,
		HTTP: &http.Client{
			Timeout: timeout,
			Transport: &http.Transport{
				Proxy:               http.ProxyURL(pu),
				DisableKeepAlives:   true, // each poll is a fresh connection through the tunnel
				TLSHandshakeTimeout: timeout,
			},
		},
	}, nil
}

// Probe performs one through-tunnel GET. It returns nil ONLY on a 2xx response
// with a non-empty body — proof a real request egressed and returned this cycle.
// Every failure mode returns a non-nil error so the caller leaves LiveProbeAt zero
// (fail-closed). It honours ctx cancellation/timeout and never fabricates success.
func (p *TunnelProxyProber) Probe(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.Target, nil)
	if err != nil {
		return fmt.Errorf("liveness: build request %s: %w", p.Target, err)
	}
	resp, err := p.HTTP.Do(req)
	if err != nil {
		// Kill-switch block / timeout / DNS failure when the tunnel is down.
		return fmt.Errorf("liveness: through-tunnel GET %s: %w", p.Target, err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<12))
	if err != nil {
		return fmt.Errorf("liveness: read %s: %w", p.Target, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("liveness: through-tunnel GET %s: status %d", p.Target, resp.StatusCode)
	}
	if len(bytes.TrimSpace(body)) == 0 {
		return fmt.Errorf("liveness: through-tunnel GET %s: empty body (no real response)", p.Target)
	}
	return nil
}

// compile-time assertion that *TunnelProxyProber satisfies the contract.
var _ LivenessProber = (*TunnelProxyProber)(nil)
