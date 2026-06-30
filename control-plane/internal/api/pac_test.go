package api

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"digital.vasic.helixproxy/controlplane/internal/store"
)

func readAll(t *testing.T, r io.Reader) string {
	t.Helper()
	b, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return string(b)
}

// TestPAC_Endpoint scrapes the REAL /proxy.pac over mTLS and asserts a usable PAC:
// a FindProxyForURL function, a mapping line for each ENABLED target alias, and
// the DIRECT default — disabled targets are absent (split-tunnel, spec §11 ⑤).
func TestPAC_Endpoint(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	ctx := context.Background()
	_, _ = h.q.UpsertTarget(ctx, store.TargetHost{PublicAlias: "wiki.helix", PrivateIP: "10.8.0.2", Port: 443, Enabled: true})
	_, _ = h.q.UpsertTarget(ctx, store.TargetHost{PublicAlias: "metrics.helix", PrivateIP: "10.8.0.3", Port: 80, Enabled: true})
	_, _ = h.q.UpsertTarget(ctx, store.TargetHost{PublicAlias: "disabled.helix", PrivateIP: "10.8.0.9", Port: 80, Enabled: false})

	resp, err := c.Get(h.url + "/proxy.pac")
	if err != nil {
		t.Fatalf("GET /proxy.pac: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/proxy.pac: want 200, got %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/javascript") {
		t.Fatalf("/proxy.pac content-type: want text/javascript, got %q", ct)
	}
	body := readAll(t, resp.Body)

	if !strings.Contains(body, "function FindProxyForURL(url, host)") {
		t.Fatalf("PAC missing FindProxyForURL:\n%s", body)
	}
	if !strings.Contains(body, `shExpMatch(host, "wiki.helix")`) ||
		!strings.Contains(body, `shExpMatch(host, "metrics.helix")`) {
		t.Fatalf("PAC missing enabled-target mappings:\n%s", body)
	}
	if strings.Contains(body, "disabled.helix") {
		t.Fatalf("PAC must not route a disabled target:\n%s", body)
	}
	if !strings.Contains(body, `return "DIRECT";`) {
		t.Fatalf("PAC missing DIRECT default:\n%s", body)
	}
}
