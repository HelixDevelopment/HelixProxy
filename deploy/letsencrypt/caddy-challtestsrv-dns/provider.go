// Package challtestsrv implements a Caddy DNS provider module that solves the
// ACME DNS-01 challenge against a pebble-challtestsrv mock DNS server via its
// unauthenticated HTTP management API (POST /set-txt and /clear-txt, default
// listener :8055). It exists so that stock Caddy — which ships NO DNS-provider
// modules and cannot drive challtestsrv's bespoke API — can run the DNS-01 code
// path end-to-end, fully offline, against the SAME challtestsrv the local Pebble
// ACME server queries for validation (see docs/research/letsencrypt_hermetic_*/
// ANALYSIS.md, "Option A").
//
// HERMETIC-TEST-ONLY. challtestsrv offers NO authentication whatsoever and MUST
// be used only inside a controlled, offline test network (Let's Encrypt
// challtestsrv README). Do NOT point this provider at any real DNS zone. For a
// real DNS-01 provider use the operator's caddy-dns/<provider> module instead.
//
// Interface target (§11.4.6 — stated, not guessed): libdns v0.2.x struct-based
// Record API (Type/Name/Value/TTL). In Caddy v2.8.x, the tls `dns` subdirective
// loads a module from the `dns.providers.*` namespace and type-asserts it to
// certmagic.DNSProvider, which is exactly libdns.RecordAppender +
// libdns.RecordDeleter — the two methods this Provider implements. See README
// "Version compatibility" for the Caddy >= 2.10 (libdns v1.0.0) adaptation.
package challtestsrv

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	"github.com/libdns/libdns"
)

// defaultMgmtURL is the pod-internal challtestsrv management API base URL used
// when the Caddyfile supplies none (service name `challtestsrv`, -management
// default :8055 — ANALYSIS.md Q2).
const defaultMgmtURL = "http://challtestsrv:8055"

func init() {
	caddy.RegisterModule(Provider{})
}

// Provider is the Caddy DNS provider module `dns.providers.challtestsrv`.
//
// It carries no credentials: challtestsrv's management API is unauthenticated by
// design, so unlike a real caddy-dns provider there is NO token field and NO
// secret to mount (§11.4.10 — nothing to leak on this hermetic path).
type Provider struct {
	// ManagementURL is the base URL of the challtestsrv HTTP management API (the
	// -management listener). Caddy global/env placeholders such as
	// {$CHALLTESTSRV_MGMT_URL} / {env.CHALLTESTSRV_MGMT_URL} are expanded in
	// Provision. Empty => defaultMgmtURL (http://challtestsrv:8055).
	ManagementURL string `json:"management_url,omitempty"`

	httpClient *http.Client
}

// CaddyModule returns the Caddy module registration, placing this provider in
// the `dns.providers` namespace so `tls { dns challtestsrv ... }` resolves it.
func (Provider) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{
		ID:  "dns.providers.challtestsrv",
		New: func() caddy.Module { return &Provider{} },
	}
}

// Provision expands placeholders in ManagementURL, applies the default and
// builds the HTTP client. Runs once when Caddy loads the config.
func (p *Provider) Provision(ctx caddy.Context) error {
	repl := caddy.NewReplacer()
	p.ManagementURL = strings.TrimRight(repl.ReplaceAll(p.ManagementURL, ""), "/")
	if p.ManagementURL == "" {
		p.ManagementURL = defaultMgmtURL
	}
	if p.httpClient == nil {
		p.httpClient = &http.Client{Timeout: 10 * time.Second}
	}
	return nil
}

// UnmarshalCaddyfile parses the site-block DNS provider directive:
//
//	dns challtestsrv [<management_url>] {
//	    management_url <url>
//	}
//
// Both the inline positional argument and the `management_url` subdirective are
// accepted; the subdirective wins if both are present.
func (p *Provider) UnmarshalCaddyfile(d *caddyfile.Dispenser) error {
	for d.Next() {
		if d.NextArg() {
			p.ManagementURL = d.Val()
		}
		if d.NextArg() {
			return d.ArgErr()
		}
		for nesting := d.Nesting(); d.NextBlock(nesting); {
			switch d.Val() {
			case "management_url":
				if !d.NextArg() {
					return d.ArgErr()
				}
				p.ManagementURL = d.Val()
			default:
				return d.Errf("unrecognized challtestsrv subdirective %q", d.Val())
			}
		}
	}
	return nil
}

// AppendRecords publishes each record's TXT value at its FQDN via /set-txt.
// Caddy calls this to present the _acme-challenge TXT for DNS-01; challtestsrv
// then answers Pebble's VA TXT query with that value.
func (p *Provider) AppendRecords(ctx context.Context, zone string, recs []libdns.Record) ([]libdns.Record, error) {
	for _, rec := range recs {
		host := fqdn(rec.Name, zone)
		if err := p.post(ctx, "/set-txt", map[string]string{"host": host, "value": rec.Value}); err != nil {
			return nil, fmt.Errorf("challtestsrv set-txt %q: %w", host, err)
		}
	}
	return recs, nil
}

// DeleteRecords clears each record's TXT at its FQDN via /clear-txt. Caddy calls
// this to clean up the challenge record after validation (§11.4.14 quiescence).
func (p *Provider) DeleteRecords(ctx context.Context, zone string, recs []libdns.Record) ([]libdns.Record, error) {
	for _, rec := range recs {
		host := fqdn(rec.Name, zone)
		if err := p.post(ctx, "/clear-txt", map[string]string{"host": host}); err != nil {
			return nil, fmt.Errorf("challtestsrv clear-txt %q: %w", host, err)
		}
	}
	return recs, nil
}

// fqdn joins the (possibly relative) record name with the zone into an absolute
// name and GUARANTEES a single trailing dot — challtestsrv REQUIRES the trailing
// '.' on set-txt/clear-txt host names or the record silently never matches
// (ANALYSIS.md Q6 gotcha #5).
func fqdn(name, zone string) string {
	full := libdns.AbsoluteName(name, zone)
	if !strings.HasSuffix(full, ".") {
		full += "."
	}
	return full
}

// post sends a JSON body to a challtestsrv management endpoint and treats any
// non-2xx response as an error (with a bounded body snippet for diagnosis).
func (p *Provider) post(ctx context.Context, path string, payload map[string]string) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.ManagementURL+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("management API %s returned %d: %s", path, resp.StatusCode, strings.TrimSpace(string(snippet)))
	}
	return nil
}

// Compile-time interface guards — the module MUST satisfy Caddy's provisioner +
// Caddyfile unmarshaler and libdns' append/delete (== certmagic.DNSProvider).
var (
	_ caddy.Provisioner     = (*Provider)(nil)
	_ caddyfile.Unmarshaler = (*Provider)(nil)
	_ libdns.RecordAppender = (*Provider)(nil)
	_ libdns.RecordDeleter  = (*Provider)(nil)
)
