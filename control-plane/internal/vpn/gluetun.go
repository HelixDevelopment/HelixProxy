// gluetun.go — a minimal stdlib client for the gluetun control API (design spec
// §4 component 1, §5; spike G4 `docs/research/mvp/findings/F_spikes_G1-G4.md`).
// gluetun is pinned to v3.40 (=v3.40.4); the control server listens on :8000 and
// answers:
//
//	GET /v1/vpn/status   → {"status":"running"|"stopped"}   (HTTP 200)
//	GET /v1/publicip/ip  → {"public_ip":"<ip>"}             (HTTP 200; "" when no
//	                                                          real egress)
//
// CONFIRMED FACT (G4): the control server answers 200 even with no real tunnel,
// and /v1/publicip/ip returns an EMPTY public_ip in that case. Therefore a
// "running" status is necessary-but-NOT-sufficient — the data-plane truth is the
// non-empty egress IP (+ wg byte-delta, see wg.go), per §11.4.107 / §11.4.69.
// Stdlib only (net/http + encoding/json); no third-party deps.
package vpn

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// ControlClient talks to one gluetun container's control API.
type ControlClient struct {
	// BaseURL is the control-server origin, e.g. "http://127.0.0.1:8000".
	BaseURL string
	// HTTP is the client used for requests; if nil a 3s-timeout client is used.
	HTTP *http.Client
}

// NewControlClient builds a client for baseURL with a sane default timeout.
func NewControlClient(baseURL string) *ControlClient {
	return &ControlClient{
		BaseURL: strings.TrimRight(baseURL, "/"),
		HTTP:    &http.Client{Timeout: 3 * time.Second},
	}
}

func (c *ControlClient) httpClient() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{Timeout: 3 * time.Second}
}

// getJSON performs GET BaseURL+path and decodes the JSON body into v.
func (c *ControlClient) getJSON(ctx context.Context, path string, v any) error {
	url := c.BaseURL + path
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("gluetun: build request %s: %w", url, err)
	}
	resp, err := c.httpClient().Do(req)
	if err != nil {
		return fmt.Errorf("gluetun: GET %s: %w", url, err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		return fmt.Errorf("gluetun: read %s: %w", url, err)
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("gluetun: GET %s: status %d: %s", url, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	if err := json.Unmarshal(body, v); err != nil {
		return fmt.Errorf("gluetun: decode %s: %w", url, err)
	}
	return nil
}

// vpnStatusResp models GET /v1/vpn/status.
type vpnStatusResp struct {
	Status string `json:"status"`
}

// publicIPResp models GET /v1/publicip/ip.
type publicIPResp struct {
	PublicIP string `json:"public_ip"`
}

// Status returns the raw control-plane status string ("running" / "stopped").
// This is metadata, NOT health: "running" alone is never proof a tunnel carries
// traffic (G4) — use EgressIP + wg byte-delta for the data-plane verdict.
func (c *ControlClient) Status(ctx context.Context) (string, error) {
	var r vpnStatusResp
	if err := c.getJSON(ctx, "/v1/vpn/status", &r); err != nil {
		return "", err
	}
	return r.Status, nil
}

// EgressIP returns the observed public egress IP through the tunnel. It is "" when
// gluetun reports no real egress (the fail-closed signal, confirmed by G4).
func (c *ControlClient) EgressIP(ctx context.Context, profile string) (string, error) {
	_ = profile // one ControlClient == one gluetun container == one profile
	var r publicIPResp
	if err := c.getJSON(ctx, "/v1/publicip/ip", &r); err != nil {
		return "", err
	}
	return strings.TrimSpace(r.PublicIP), nil
}
