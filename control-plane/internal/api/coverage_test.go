// Additional real unit tests for the control-API branches the happy-path CRUD +
// atomicity + list-error suites do not reach: the putRule unknown-id 404, the
// putTarget port-range 400, the decodeJSON / DisallowUnknownFields 400 for every
// mutating endpoint, the proxyPAC store-error 500, the store MUTATION-error and
// GET-error 500 fail-loud paths (a store fault surfaces as 500, never a bluffed
// 200), the events streaming-unsupported 500 + subscribe-error 502, the
// actorFromRequest "unknown" fallback when no verified peer cert is present, and
// the metrics IncACLDecision invalid→ERR normalisation + the vpnUpCollector
// store-error series-suppression (§11.4.6 — no fabricated gauge on a store error).
//
// The store-fault paths use errQueries (an in-package store.Queries wrapper that
// injects Get*/Upsert*/Delete* errors — fakes are unit-test-only, §11.4.27) driven
// through the REAL router (Handler().ServeHTTP), so the actual handler + routing
// code runs. Every assertion catches a real regression: flipping a handler's error
// branch back to a silent 200 (or dropping a validation guard) makes a test FAIL.
package api

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"digital.vasic.helixproxy/controlplane/internal/pac"
	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/store"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// --- store-fault injection (unit-test only, §11.4.27) -----------------------

// errQueries wraps a *fakeQueries and injects a store error into Get*/mutations so
// the fail-loud 500 paths (and the mutateWithAudit inner mutation-error return)
// are exercised. WithTx runs the closure against THIS wrapper so the overridden
// mutators are the ones the transaction calls (the embedded fake's WithTx would
// otherwise pass the raw fake and bypass the injection). getErr drives the generic
// GET 500 (a non-ErrNotFound store error); mutErr drives every mutation 500.
type errQueries struct {
	*fakeQueries
	getErr error
	mutErr error
}

func (e *errQueries) GetProfile(ctx context.Context, id string) (store.VPNProfile, error) {
	if e.getErr != nil {
		return store.VPNProfile{}, e.getErr
	}
	return e.fakeQueries.GetProfile(ctx, id)
}
func (e *errQueries) GetTargetHost(ctx context.Context, alias string) (store.TargetHost, error) {
	if e.getErr != nil {
		return store.TargetHost{}, e.getErr
	}
	return e.fakeQueries.GetTargetHost(ctx, alias)
}
func (e *errQueries) GetRuleByHost(ctx context.Context, host string) (store.ProxyRule, error) {
	if e.getErr != nil {
		return store.ProxyRule{}, e.getErr
	}
	return e.fakeQueries.GetRuleByHost(ctx, host)
}
func (e *errQueries) ListTiers(ctx context.Context, targetID string) ([]store.TargetTunnelTier, error) {
	if e.getErr != nil {
		return nil, e.getErr
	}
	return e.fakeQueries.ListTiers(ctx, targetID)
}

func (e *errQueries) UpsertProfile(ctx context.Context, p store.VPNProfile) (string, error) {
	if e.mutErr != nil {
		return "", e.mutErr
	}
	return e.fakeQueries.UpsertProfile(ctx, p)
}
func (e *errQueries) DeleteProfile(ctx context.Context, id string) error {
	if e.mutErr != nil {
		return e.mutErr
	}
	return e.fakeQueries.DeleteProfile(ctx, id)
}
func (e *errQueries) UpsertTarget(ctx context.Context, t store.TargetHost) (string, error) {
	if e.mutErr != nil {
		return "", e.mutErr
	}
	return e.fakeQueries.UpsertTarget(ctx, t)
}
func (e *errQueries) DeleteTarget(ctx context.Context, id string) error {
	if e.mutErr != nil {
		return e.mutErr
	}
	return e.fakeQueries.DeleteTarget(ctx, id)
}
func (e *errQueries) UpsertRule(ctx context.Context, r store.ProxyRule) (string, error) {
	if e.mutErr != nil {
		return "", e.mutErr
	}
	return e.fakeQueries.UpsertRule(ctx, r)
}
func (e *errQueries) DeleteRule(ctx context.Context, id string) error {
	if e.mutErr != nil {
		return e.mutErr
	}
	return e.fakeQueries.DeleteRule(ctx, id)
}
func (e *errQueries) UpsertTier(ctx context.Context, t store.TargetTunnelTier) error {
	if e.mutErr != nil {
		return e.mutErr
	}
	return e.fakeQueries.UpsertTier(ctx, t)
}
func (e *errQueries) DeleteTier(ctx context.Context, targetID string, tier int) error {
	if e.mutErr != nil {
		return e.mutErr
	}
	return e.fakeQueries.DeleteTier(ctx, targetID, tier)
}
func (e *errQueries) UpsertUser(ctx context.Context, u store.ProxyUser) (string, error) {
	if e.mutErr != nil {
		return "", e.mutErr
	}
	return e.fakeQueries.UpsertUser(ctx, u)
}

// WithTx runs fn against the wrapper (so overridden mutators are used) but delegates
// snapshot/rollback to the embedded fake's WithTx (a rolled-back mutation stays
// rolled back exactly as the real store.WithTx guarantees).
func (e *errQueries) WithTx(ctx context.Context, fn func(tx store.Queries) error) error {
	return e.fakeQueries.WithTx(ctx, func(_ store.Queries) error { return fn(e) })
}

// subErrBus is a StatusBus whose SubscribeEvents always fails — drives the events
// handler's 502 "event bus unavailable" path.
type subErrBus struct{ *fakeBus }

func (b *subErrBus) SubscribeEvents(context.Context) (<-chan redis.Event, error) {
	return nil, errors.New("subscribe failed: bus unavailable")
}

// nonFlusherRW is an http.ResponseWriter that deliberately does NOT implement
// http.Flusher — drives the events handler's "streaming unsupported" 500 branch.
type nonFlusherRW struct {
	hdr  http.Header
	code int
	body strings.Builder
}

func (w *nonFlusherRW) Header() http.Header {
	if w.hdr == nil {
		w.hdr = http.Header{}
	}
	return w.hdr
}
func (w *nonFlusherRW) Write(b []byte) (int, error) { return w.body.Write(b) }
func (w *nonFlusherRW) WriteHeader(c int)           { w.code = c }

// newDirectServer builds a *server for direct-handler tests (no mTLS socket needed;
// the handlers under test do not depend on TLS beyond actorFromRequest, which is
// itself exercised here). Handler().ServeHTTP runs the REAL router + handler.
func newDirectServer(t *testing.T, q store.Queries, bus redis.StatusBus) *server {
	t.Helper()
	return NewServer(Config{Addr: "127.0.0.1:0"}, q, bus, pac.NewGenerator()).(*server)
}

// serveMux drives the real router with no client cert (r.TLS == nil) and returns
// the status code + body.
func serveMux(t *testing.T, s *server, method, target string, body io.Reader) (int, string) {
	t.Helper()
	req := httptest.NewRequest(method, target, body)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}

// --- validation / not-found branches (over the REAL mTLS server) ------------

// TestPutRule_UnknownIDReturns404 covers putRule's ErrNotFound → 404 branch: an
// upsert of a rule carrying an ID that does not exist is a 404 ("rule id not
// found"), never a silent create under a caller-chosen id.
func TestPutRule_UnknownIDReturns404(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	code, body := doJSON(t, c, http.MethodPut, h.url+"/api/rules", ruleDTO{
		ID: "rule-does-not-exist", Priority: 1, MatchHost: "x.internal", Enabled: true,
	})
	if code != http.StatusNotFound {
		t.Fatalf("PUT rule with unknown id: want 404, got %d (%s)", code, body)
	}
	if !strings.Contains(string(body), "rule id not found") {
		t.Fatalf("PUT rule 404 body: want 'rule id not found', got %s", body)
	}
	if n := h.q.auditCount(); n != 0 {
		t.Fatalf("a 404 must not write an audit row: got %d", n)
	}
}

// TestPutTarget_PortOutOfRange covers putTarget's port-range 400 guard (0..65535),
// on both the negative and the too-large boundary — rejected before any store write.
func TestPutTarget_PortOutOfRange(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	for _, port := range []int{-1, 70000} {
		code, _ := doJSON(t, c, http.MethodPut, h.url+"/api/targets", targetDTO{
			PublicAlias: "a.internal", PrivateIP: "10.0.0.1", Port: port, Enabled: true,
		})
		if code != http.StatusBadRequest {
			t.Fatalf("PUT target port=%d: want 400, got %d", port, code)
		}
	}
	if n := h.q.auditCount(); n != 0 {
		t.Fatalf("rejected port must not audit: got %d", n)
	}
}

// TestPut_MalformedJSONRejected covers the decodeJSON error → 400 branch of every
// mutating endpoint (and decodeJSON's DisallowUnknownFields: an unexpected field is
// rejected, never silently ignored — a real defence against typo'd/injected keys).
func TestPut_MalformedJSONRejected(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	for _, path := range []string{"/api/profiles", "/api/targets", "/api/rules", "/api/tiers", "/api/users"} {
		// unknown field → DisallowUnknownFields decode error → 400
		if code := doRawBody(t, c, http.MethodPut, h.url+path, `{"unexpected_field":true}`); code != http.StatusBadRequest {
			t.Fatalf("PUT %s unknown-field: want 400, got %d", path, code)
		}
		// truncated/invalid JSON → decode error → 400
		if code := doRawBody(t, c, http.MethodPut, h.url+path, `{"name":`); code != http.StatusBadRequest {
			t.Fatalf("PUT %s malformed JSON: want 400, got %d", path, code)
		}
	}
	if n := h.q.auditCount(); n != 0 {
		t.Fatalf("malformed requests must not audit: got %d", n)
	}
}

// TestProxyPAC_StoreErrorReturns500 covers proxyPAC's ListTargets error → 500: a
// PAC build that cannot read targets fails LOUD, never serves a bluffed empty PAC.
func TestProxyPAC_StoreErrorReturns500(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)
	setListErr(h.q, errors.New("db down"))

	resp, err := c.Get(h.url + "/proxy.pac")
	if err != nil {
		t.Fatalf("GET /proxy.pac: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("/proxy.pac with store error: want 500, got %d", resp.StatusCode)
	}
}

// --- store-fault 500 paths (direct handler via the real router) -------------

// TestGetHandlers_StoreErrorReturns500 covers the generic (non-ErrNotFound) store
// error → 500 branch of getProfile/getTarget/getRuleByHost: a transport/db error is
// a 500, distinct from the ErrNotFound 404 (which is already covered) — never a 200.
func TestGetHandlers_StoreErrorReturns500(t *testing.T) {
	q := &errQueries{fakeQueries: newFakeQueries(), getErr: errors.New("db read error")}
	s := newDirectServer(t, q, newFakeBus())

	for _, target := range []string{"/api/profiles/x", "/api/targets/x", "/api/rules/x", "/api/tiers/x"} {
		if code, _ := serveMux(t, s, http.MethodGet, target, nil); code != http.StatusInternalServerError {
			t.Fatalf("GET %s with store error: want 500, got %d", target, code)
		}
	}
}

// TestMutateHandlers_StoreErrorReturns500 covers the mutation-error path of every
// mutating handler: when the store mutation itself fails, mutateWithAudit's inner
// error return propagates and the handler returns 500 (fail-loud) — and the failed
// transaction leaves NO audit row (the mutation never reached the audit append).
func TestMutateHandlers_StoreErrorReturns500(t *testing.T) {
	fake := newFakeQueries()
	q := &errQueries{fakeQueries: fake, mutErr: errors.New("db write error")}
	s := newDirectServer(t, q, newFakeBus())

	cases := []struct {
		method, target, body string
	}{
		{http.MethodPut, "/api/profiles", `{"name":"p","enabled":true}`},
		{http.MethodDelete, "/api/profiles/some-id", ""},
		{http.MethodPut, "/api/targets", `{"public_alias":"a.internal","private_ip":"10.0.0.1","port":443,"enabled":true}`},
		{http.MethodDelete, "/api/targets/some-id", ""},
		{http.MethodPut, "/api/rules", `{"match_host":"h.internal","enabled":true}`},
		{http.MethodDelete, "/api/rules/some-id", ""},
		{http.MethodPut, "/api/tiers", `{"target_id":"t","vpn_profile_id":"p","tier":0}`},
		{http.MethodDelete, "/api/tiers/t/0", ""},
		{http.MethodPut, "/api/users", `{"username":"u","enabled":true}`},
	}
	for _, tc := range cases {
		var rdr io.Reader
		if tc.body != "" {
			rdr = strings.NewReader(tc.body)
		}
		if code, _ := serveMux(t, s, tc.method, tc.target, rdr); code != http.StatusInternalServerError {
			t.Fatalf("%s %s with store mutation error: want 500, got %d", tc.method, tc.target, code)
		}
	}
	if n := fake.auditCount(); n != 0 {
		t.Fatalf("failed mutations must leave NO audit row: got %d", n)
	}
}

// TestActorUnknown_WhenNoClientCert covers actorFromRequest's fallback: a request
// with no verified peer cert (r.TLS == nil) records the audit actor as "unknown",
// never an empty string and never a panic. Driven through the real router so the
// mutation + audit path runs end-to-end.
func TestActorUnknown_WhenNoClientCert(t *testing.T) {
	fake := newFakeQueries()
	s := newDirectServer(t, fake, newFakeBus())

	code, body := serveMux(t, s, http.MethodPut, "/api/profiles", strings.NewReader(`{"name":"noc","enabled":true}`))
	if code != http.StatusOK {
		t.Fatalf("PUT profile (no client cert): want 200, got %d (%s)", code, body)
	}
	if n := fake.auditCount(); n != 1 {
		t.Fatalf("mutation must write exactly 1 audit row: got %d", n)
	}
	if got := fake.audits[0].Actor; got != "unknown" {
		t.Fatalf("audit actor with no verified peer cert: want 'unknown', got %q", got)
	}
}

// --- SSE error branches (direct handler) ------------------------------------

// TestEvents_StreamingUnsupported covers events' first fail-closed branch: a
// ResponseWriter that is not an http.Flusher yields a 500 "streaming unsupported"
// rather than a half-open stream that would silently never flush.
func TestEvents_StreamingUnsupported(t *testing.T) {
	s := newDirectServer(t, newFakeQueries(), newFakeBus())
	w := &nonFlusherRW{}
	req := httptest.NewRequest(http.MethodGet, "/events", nil)

	s.events(w, req)

	if w.code != http.StatusInternalServerError {
		t.Fatalf("events with non-flusher writer: want 500, got %d", w.code)
	}
	if !strings.Contains(w.body.String(), "streaming unsupported") {
		t.Fatalf("events non-flusher body: want 'streaming unsupported', got %s", w.body.String())
	}
}

// TestEvents_SubscribeErrorReturns502 covers events' subscribe-error branch: when
// the event bus subscription fails, the handler returns 502 "event bus unavailable"
// (an upstream dependency failure), never a 200 empty stream.
func TestEvents_SubscribeErrorReturns502(t *testing.T) {
	s := newDirectServer(t, newFakeQueries(), &subErrBus{fakeBus: newFakeBus()})
	rec := httptest.NewRecorder() // ResponseRecorder IS a Flusher, so the flusher check passes
	req := httptest.NewRequest(http.MethodGet, "/events", nil)

	s.events(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("events with subscribe error: want 502, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "event bus unavailable") {
		t.Fatalf("events 502 body: want 'event bus unavailable', got %s", rec.Body.String())
	}
}

// --- metrics branches -------------------------------------------------------

// TestIncACLDecision_NormalizesInvalidToERR covers IncACLDecision's fail-closed
// normalisation: an out-of-vocabulary decision label is folded to "ERR" (never a
// new arbitrary label series, never dropped). Scraped over the REAL promhttp
// handler so the assertion reads the actual exposition body.
func TestIncACLDecision_NormalizesInvalidToERR(t *testing.T) {
	m := newMetrics(newFakeQueries(), newFakeBus())
	m.IncACLDecision("TOTALLY-BOGUS")

	body := scrapeMetrics(t, m)
	if !regexp.MustCompile(`helix_proxy_acl_decisions_total\{decision="ERR"\}\s+1`).MatchString(body) {
		t.Fatalf("invalid decision must fold to ERR (=1)\n%s", body)
	}
	if !regexp.MustCompile(`helix_proxy_acl_decisions_total\{decision="OK"\}\s+0`).MatchString(body) {
		t.Fatalf("OK series must stay 0 (invalid label must NOT count as OK)\n%s", body)
	}
	if strings.Contains(body, `decision="TOTALLY-BOGUS"`) {
		t.Fatalf("invalid label must NOT create its own series\n%s", body)
	}
}

// TestVPNUpCollector_StoreErrorSuppressesSeries covers vpnUpCollector.Collect's
// store-error branch (§11.4.6): with a profile seeded UP the gauge is present at 1;
// once ListProfiles errors, Collect emits NO series (never a fabricated value). The
// two-phase assertion proves the ABSENCE is caused by the error, not an empty store.
func TestVPNUpCollector_StoreErrorSuppressesSeries(t *testing.T) {
	q := newFakeQueries()
	bus := newFakeBus()
	if _, err := q.UpsertProfile(context.Background(), store.VPNProfile{
		Name: "eu-wg", Type: store.VPNTypeWireGuard, Enabled: true,
	}); err != nil {
		t.Fatalf("seed profile: %v", err)
	}
	bus.setStatus("eu-wg", vpn.StateUp)
	m := newMetrics(q, bus)

	// Phase 1: healthy store → the gauge is present and reports 1 (up).
	if body := scrapeMetrics(t, m); !regexp.MustCompile(`helix_proxy_vpn_up\{profile="eu-wg"\}\s+1`).MatchString(body) {
		t.Fatalf("with a healthy store the gauge must be present (=1)\n%s", body)
	}

	// Phase 2: store error at scrape time → NO vpn_up series at all (no fabricated gauge).
	setListErr(q, errors.New("db down"))
	if body := scrapeMetrics(t, m); strings.Contains(body, "helix_proxy_vpn_up{") {
		t.Fatalf("on a store error the vpn_up gauge must be suppressed, not fabricated\n%s", body)
	}
}

// --- TLS / server bootstrap fail-closed branches ----------------------------

// TestBuildTLSConfig_Errors covers buildTLSConfig's fail-closed error branches: a
// server that cannot load its cert/key or a usable client CA MUST refuse to build a
// TLS config rather than silently downgrade mTLS. Uses throwaway in-process certs
// (never committed key material, §11.4.10). The all-good path additionally asserts
// the fail-closed RequireAndVerifyClientCert is set.
func TestBuildTLSConfig_Errors(t *testing.T) {
	// (1) missing paths → hard error.
	if _, err := buildTLSConfig(Config{}); err == nil {
		t.Fatal("empty TLS paths must be a hard error (fail-closed, no silent downgrade)")
	}

	dir := t.TempDir()
	ca, caKey, caPEM := mustGenCA(t)
	leaf := mustGenLeaf(t, ca, caKey, "helix-control-plane",
		[]x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		[]net.IP{net.ParseIP("127.0.0.1")}, []string{"localhost"})
	goodCert := writeFile(t, dir, "s.crt", leaf.certPEM)
	goodKey := writeFile(t, dir, "s.key", leaf.keyPEM)
	goodCA := writeFile(t, dir, "ca.crt", caPEM.certPEM)

	// (2) unparseable server keypair → error.
	badCert := writeFile(t, dir, "bad.crt", []byte("not a pem certificate"))
	if _, err := buildTLSConfig(Config{TLSCert: badCert, TLSKey: goodKey, ClientCA: goodCA}); err == nil {
		t.Fatal("an unparseable server keypair must error")
	}
	// (3) unreadable client-CA path → error.
	if _, err := buildTLSConfig(Config{TLSCert: goodCert, TLSKey: goodKey, ClientCA: filepath.Join(dir, "nope.crt")}); err == nil {
		t.Fatal("a missing client-CA file must error")
	}
	// (4) client CA with no usable certificates → error.
	emptyCA := writeFile(t, dir, "empty-ca.crt", []byte("-----BEGIN NONSENSE-----\nzzz\n-----END NONSENSE-----\n"))
	if _, err := buildTLSConfig(Config{TLSCert: goodCert, TLSKey: goodKey, ClientCA: emptyCA}); err == nil {
		t.Fatal("a client CA with no usable certificates must error")
	}
	// (5) all-good → a config that REQUIRES + VERIFIES the client cert (fail-closed).
	cfg, err := buildTLSConfig(Config{TLSCert: goodCert, TLSKey: goodKey, ClientCA: goodCA})
	if err != nil {
		t.Fatalf("valid config: unexpected error %v", err)
	}
	if cfg.ClientAuth != tls.RequireAndVerifyClientCert {
		t.Fatalf("buildTLSConfig must set RequireAndVerifyClientCert (fail-closed), got %v", cfg.ClientAuth)
	}
}

// TestStart_FailsFastOnBadTLSConfig covers Start's buildTLSConfig-error branch: with
// no TLS paths Start returns the error immediately and binds NO socket — there is no
// plaintext fallback (spec §10/§12 fail-closed).
func TestStart_FailsFastOnBadTLSConfig(t *testing.T) {
	s := newDirectServer(t, newFakeQueries(), newFakeBus())
	if err := s.Start(context.Background()); err == nil {
		t.Fatal("Start with no TLS config must return an error (fail-closed, no plaintext fallback)")
	}
}

// TestStartMetricsListener_BindError covers startMetricsListener's bind-failure
// branch: a misconfigured metrics address is surfaced as an error, never a silent
// no-op (fail-closed on a bad CONTROL_API_METRICS_ADDR). Port 999999 is out of the
// valid TCP range so net.Listen always fails.
func TestStartMetricsListener_BindError(t *testing.T) {
	s := newMetricsListenerServer(t, "127.0.0.1:999999")
	hs, addr, err := s.startMetricsListener()
	if err == nil {
		if hs != nil {
			_ = hs.Close()
		}
		t.Fatalf("startMetricsListener with an unbindable addr must error, got addr=%q", addr)
	}
	if hs != nil || addr != "" {
		t.Fatalf("a bind failure must yield no server/addr, got hs=%v addr=%q", hs, addr)
	}
}

// --- helpers ----------------------------------------------------------------

// doRawBody issues a mTLS request with a raw (possibly invalid-JSON) body and
// returns the status code — used to hit decode-error branches doJSON cannot reach
// (json.Marshal of an invalid json.RawMessage would fail before the request).
func doRawBody(t *testing.T, c *http.Client, method, url, raw string) int {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(raw))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

// scrapeMetrics serves the metrics registry over the REAL promhttp handler and
// returns the exposition text (white-box: same package as the registry).
func scrapeMetrics(t *testing.T, m *Metrics) string {
	t.Helper()
	rec := httptest.NewRecorder()
	m.handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("scrape /metrics: want 200, got %d", rec.Code)
	}
	return rec.Body.String()
}
