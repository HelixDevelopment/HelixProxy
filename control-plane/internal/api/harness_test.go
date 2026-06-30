// Test harness for the control-API: in-process cert generation (a throwaway CA +
// server cert + client cert — NEVER committed, §11.4.10), a real mTLS httptest
// server built through the PRODUCTION buildTLSConfig (so the §1.1-guarded
// fail-closed line is the code under test), and in-memory fakes for the committed
// store.Queries + redis.StatusBus interfaces (fakes are permitted in unit tests
// only — §11.4.27). Tests drive REAL HTTP/JSON/SSE/PAC/metrics over this server.
package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/pac"
	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/store"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// --- cert generation --------------------------------------------------------

type certPEM struct{ certPEM, keyPEM []byte }

func mustGenCA(t *testing.T) (*x509.Certificate, *ecdsa.PrivateKey, certPEM) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("gen CA key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "helix-test-ca"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create CA cert: %v", err)
	}
	ca, _ := x509.ParseCertificate(der)
	return ca, key, certPEM{
		certPEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		keyPEM:  marshalKey(t, key),
	}
}

// mustGenLeaf signs a leaf cert (server or client) with the CA. cn is the CN that
// becomes the audit actor for client certs; ip/dns SANs matter for server certs.
func mustGenLeaf(t *testing.T, ca *x509.Certificate, caKey *ecdsa.PrivateKey, cn string, eku []x509.ExtKeyUsage, ips []net.IP, dns []string) certPEM {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("gen leaf key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  eku,
		IPAddresses:  ips,
		DNSNames:     dns,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca, &key.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create leaf cert: %v", err)
	}
	return certPEM{
		certPEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		keyPEM:  marshalKey(t, key),
	}
}

func marshalKey(t *testing.T, key *ecdsa.PrivateKey) []byte {
	t.Helper()
	b, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: b})
}

func writeFile(t *testing.T, dir, name string, data []byte) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, data, 0o600); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return p
}

// --- harness ----------------------------------------------------------------

type harness struct {
	ts        *httptest.Server
	url       string
	q         *fakeQueries
	bus       *fakeBus
	srv       *server
	clientPEM certPEM
	caPool    *x509.CertPool
}

// newHarness builds a REAL mTLS httptest server backed by in-memory fakes.
func newHarness(t *testing.T) *harness {
	t.Helper()
	q := newFakeQueries()
	bus := newFakeBus()
	h := newHarnessWith(t, q, bus)
	h.q = q
	h.bus = bus
	return h
}

// newHarnessWith builds a REAL mTLS httptest server through the production
// buildTLSConfig (so the fail-closed ClientAuth line is exercised) over the given
// backends (fakes for unit tests, real store.Postgres for the integration test).
func newHarnessWith(t *testing.T, q store.Queries, bus redis.StatusBus) *harness {
	t.Helper()
	ca, caKey, caPEM := mustGenCA(t)
	srvCert := mustGenLeaf(t, ca, caKey, "helix-control-plane",
		[]x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		[]net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}, []string{"localhost"})
	cliCert := mustGenLeaf(t, ca, caKey, "admin@helix",
		[]x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}, nil, nil)

	dir := t.TempDir()
	cfg := Config{
		Addr:     "127.0.0.1:0",
		TLSCert:  writeFile(t, dir, "server.crt", srvCert.certPEM),
		TLSKey:   writeFile(t, dir, "server.key", srvCert.keyPEM),
		ClientCA: writeFile(t, dir, "ca.crt", caPEM.certPEM),
	}

	srvAny := NewServer(cfg, q, bus, pac.NewGenerator())
	srv := srvAny.(*server)

	tlsCfg, err := buildTLSConfig(cfg) // production path, incl. the §1.1-guarded line
	if err != nil {
		t.Fatalf("buildTLSConfig: %v", err)
	}
	ts := httptest.NewUnstartedServer(srv.Handler())
	ts.TLS = tlsCfg
	ts.StartTLS()
	t.Cleanup(ts.Close)

	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caPEM.certPEM) {
		t.Fatal("append CA to pool")
	}

	// q/bus fields (fake-typed) are populated by newHarness for unit tests; the
	// integration test holds its real store separately.
	return &harness{ts: ts, url: ts.URL, srv: srv, clientPEM: cliCert, caPool: caPool}
}

// clientWithCert returns an https client that trusts the harness CA AND presents
// the harness client cert (a fully-valid mTLS peer).
func (h *harness) clientWithCert(t *testing.T) *http.Client {
	t.Helper()
	cert, err := tls.X509KeyPair(h.clientPEM.certPEM, h.clientPEM.keyPEM)
	if err != nil {
		t.Fatalf("client keypair: %v", err)
	}
	return &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: h.caPool, Certificates: []tls.Certificate{cert}},
	}}
}

// clientNoCert returns an https client that trusts the harness CA but presents NO
// client cert — used by the fail-closed test (the handshake MUST be rejected).
func (h *harness) clientNoCert() *http.Client {
	return &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: h.caPool},
	}}
}

// --- fakes (unit-test only, §11.4.27) ---------------------------------------

// fakeQueries is an in-memory store.Queries. It records audit appends so a test
// can assert "every mutation wrote an audit row".
type fakeQueries struct {
	mu       sync.Mutex
	profiles map[string]store.VPNProfile // keyed by id
	byName   map[string]string           // name -> id
	targets  map[string]store.TargetHost // keyed by id
	byAlias  map[string]string           // alias -> id
	rules    map[string]store.ProxyRule
	tiers    map[string][]store.TargetTunnelTier
	users    map[string]store.ProxyUser
	audits   []store.AuditLogEntry
	seq      int
	listErr  error // when set, List* return it (drives the 500 + collector-error paths)
}

var _ store.Queries = (*fakeQueries)(nil)

func newFakeQueries() *fakeQueries {
	return &fakeQueries{
		profiles: map[string]store.VPNProfile{}, byName: map[string]string{},
		targets: map[string]store.TargetHost{}, byAlias: map[string]string{},
		rules: map[string]store.ProxyRule{}, tiers: map[string][]store.TargetTunnelTier{},
		users: map[string]store.ProxyUser{},
	}
}

func (f *fakeQueries) nextID(prefix string) string {
	f.seq++
	return prefix + "-" + big.NewInt(int64(f.seq)).String()
}

func (f *fakeQueries) auditCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.audits)
}

func (f *fakeQueries) ListProfiles(context.Context) ([]store.VPNProfile, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.listErr != nil {
		return nil, f.listErr
	}
	out := []store.VPNProfile{}
	for _, p := range f.profiles {
		out = append(out, p)
	}
	return out, nil
}
func (f *fakeQueries) GetProfile(_ context.Context, id string) (store.VPNProfile, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if p, ok := f.profiles[id]; ok {
		return p, nil
	}
	return store.VPNProfile{}, store.ErrNotFound
}
func (f *fakeQueries) UpsertProfile(_ context.Context, p store.VPNProfile) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	id, ok := f.byName[p.Name]
	if !ok {
		id = f.nextID("prof")
		f.byName[p.Name] = id
	}
	p.ID = id
	if p.Type == "" {
		p.Type = store.VPNTypeWireGuard
	}
	if len(p.Config) == 0 {
		p.Config = []byte("{}")
	}
	f.profiles[id] = p
	return id, nil
}
func (f *fakeQueries) DeleteProfile(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if p, ok := f.profiles[id]; ok {
		delete(f.byName, p.Name)
		delete(f.profiles, id)
	}
	return nil
}

func (f *fakeQueries) ListTargets(context.Context) ([]store.TargetHost, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.listErr != nil {
		return nil, f.listErr
	}
	out := []store.TargetHost{}
	for _, t := range f.targets {
		out = append(out, t)
	}
	return out, nil
}
func (f *fakeQueries) GetTargetHost(_ context.Context, alias string) (store.TargetHost, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if id, ok := f.byAlias[alias]; ok {
		return f.targets[id], nil
	}
	return store.TargetHost{}, store.ErrNotFound
}
func (f *fakeQueries) UpsertTarget(_ context.Context, t store.TargetHost) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	id, ok := f.byAlias[t.PublicAlias]
	if !ok {
		id = f.nextID("tgt")
		f.byAlias[t.PublicAlias] = id
	}
	t.ID = id
	f.targets[id] = t
	return id, nil
}
func (f *fakeQueries) DeleteTarget(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if t, ok := f.targets[id]; ok {
		delete(f.byAlias, t.PublicAlias)
		delete(f.targets, id)
	}
	return nil
}

func (f *fakeQueries) ListRules(context.Context) ([]store.ProxyRule, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.listErr != nil {
		return nil, f.listErr
	}
	out := []store.ProxyRule{}
	for _, r := range f.rules {
		out = append(out, r)
	}
	return out, nil
}
func (f *fakeQueries) GetRuleByHost(_ context.Context, host string) (store.ProxyRule, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var best store.ProxyRule
	found := false
	for _, r := range f.rules {
		if r.Enabled && r.MatchHost == host && (!found || r.Priority > best.Priority) {
			best, found = r, true
		}
	}
	if !found {
		return store.ProxyRule{}, store.ErrNotFound
	}
	return best, nil
}
func (f *fakeQueries) UpsertRule(_ context.Context, r store.ProxyRule) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.ID == "" {
		r.ID = f.nextID("rule")
	} else if _, ok := f.rules[r.ID]; !ok {
		return "", store.ErrNotFound
	}
	f.rules[r.ID] = r
	return r.ID, nil
}
func (f *fakeQueries) DeleteRule(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.rules, id)
	return nil
}

func (f *fakeQueries) ListTiers(_ context.Context, targetID string) ([]store.TargetTunnelTier, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.tiers[targetID], nil
}
func (f *fakeQueries) UpsertTier(_ context.Context, t store.TargetTunnelTier) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	cur := f.tiers[t.TargetID]
	for i := range cur {
		if cur[i].Tier == t.Tier {
			cur[i] = t
			f.tiers[t.TargetID] = cur
			return nil
		}
	}
	f.tiers[t.TargetID] = append(cur, t)
	return nil
}
func (f *fakeQueries) DeleteTier(_ context.Context, targetID string, tier int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	cur := f.tiers[targetID]
	out := cur[:0]
	for _, x := range cur {
		if x.Tier != tier {
			out = append(out, x)
		}
	}
	f.tiers[targetID] = out
	return nil
}

func (f *fakeQueries) ListUsers(context.Context) ([]store.ProxyUser, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.listErr != nil {
		return nil, f.listErr
	}
	out := []store.ProxyUser{}
	for _, u := range f.users {
		out = append(out, u)
	}
	return out, nil
}
func (f *fakeQueries) UpsertUser(_ context.Context, u store.ProxyUser) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	id := f.nextID("user")
	u.ID = id
	f.users[u.Username] = u
	return id, nil
}

func (f *fakeQueries) AppendAudit(_ context.Context, e store.AuditLogEntry) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.audits = append(f.audits, e)
	return nil
}

// fakeBus is an in-memory redis.StatusBus. status backs the vpn_up gauge; events
// is a channel a test publishes into to drive the SSE stream.
type fakeBus struct {
	mu     sync.Mutex
	status map[string]vpn.State
	events chan redis.Event
	subErr error
}

var _ redis.StatusBus = (*fakeBus)(nil)

func newFakeBus() *fakeBus {
	return &fakeBus{status: map[string]vpn.State{}, events: make(chan redis.Event, 8)}
}

func (b *fakeBus) setStatus(profile string, st vpn.State) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.status[profile] = st
}

func (b *fakeBus) SetStatus(context.Context, vpn.HealthSnapshot, int) error { return nil }
func (b *fakeBus) GetStatus(_ context.Context, profile string) (vpn.HealthSnapshot, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	st, ok := b.status[profile]
	if !ok {
		st = vpn.StateDown // fail-closed default
	}
	return vpn.HealthSnapshot{Profile: profile, State: st, CheckedAt: time.Now()}, nil
}
func (b *fakeBus) SetRoute(context.Context, redis.Route) error { return nil }
func (b *fakeBus) GetRoute(context.Context, string) (redis.Route, error) {
	return redis.Route{}, redis.ErrRouteNotFound
}
func (b *fakeBus) PublishEvent(_ context.Context, e redis.Event) error {
	b.events <- e
	return nil
}
func (b *fakeBus) SubscribeEvents(ctx context.Context) (<-chan redis.Event, error) {
	if b.subErr != nil {
		return nil, b.subErr
	}
	out := make(chan redis.Event)
	go func() {
		defer close(out)
		for {
			select {
			case <-ctx.Done():
				return
			case e := <-b.events:
				select {
				case out <- e:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return out, nil
}
