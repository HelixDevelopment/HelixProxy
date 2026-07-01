// Concrete control-API server (design spec §4 component 4, §11 ③⑤⑥). It serves
// REST CRUD over the store, the SSE live-event stream, the Prometheus /metrics
// endpoint, and the PAC file — all over mTLS (tls.go). The byte path stays out of
// the control plane: this server reads/writes the data model + the live status
// bus; the proxies route per request via the acl-helper + Redis (spec §8/§9).
package api

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/pac"
	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/store"
)

// server is the concrete Server. It depends only on the committed interfaces
// (store.Queries, redis.StatusBus, pac.Generator), so it is testable with fakes
// in unit tests and wired to the real pgx/go-redis clients in cmd/api.
type server struct {
	cfg     Config
	q       store.Queries
	bus     redis.StatusBus
	gen     pac.Generator
	metrics *Metrics
	mux     *http.ServeMux

	mu          sync.Mutex // guards metricsAddr
	metricsAddr string     // bound plaintext /metrics listener addr ("" = off/not bound)
}

// compile-time assertion that *server satisfies the Server contract.
var _ Server = (*server)(nil)

// NewServer builds a control-API server over the given backends. The Prometheus
// registry + collectors are constructed here (one registry per server). It does
// NOT bind a socket — Start does that.
func NewServer(cfg Config, q store.Queries, bus redis.StatusBus, gen pac.Generator) Server {
	s := &server{cfg: cfg, q: q, bus: bus, gen: gen}
	s.metrics = newMetrics(q, bus)
	s.mux = s.routes()
	return s
}

// Metrics exposes the registered counters so the acl-helper / byte-path can drive
// them later (helix_proxy_acl_decisions_total / _tunnel_down_responses_total).
func (s *server) Metrics() *Metrics { return s.metrics }

// Handler returns the fully-wired router (used by Start and by the tests).
func (s *server) Handler() http.Handler { return s.mux }

// routes wires the URL space. Go 1.22+ method+pattern routing gives 405/404 for
// free; {id}/{alias}/{host}/{targetID}/{tier} are path wildcards.
func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()

	// profiles
	mux.HandleFunc("GET /api/profiles", s.listProfiles)
	mux.HandleFunc("GET /api/profiles/{id}", s.getProfile)
	mux.HandleFunc("PUT /api/profiles", s.putProfile)
	mux.HandleFunc("DELETE /api/profiles/{id}", s.deleteProfile)

	// targets
	mux.HandleFunc("GET /api/targets", s.listTargets)
	mux.HandleFunc("GET /api/targets/{alias}", s.getTarget)
	mux.HandleFunc("PUT /api/targets", s.putTarget)
	mux.HandleFunc("DELETE /api/targets/{id}", s.deleteTarget)

	// rules
	mux.HandleFunc("GET /api/rules", s.listRules)
	mux.HandleFunc("GET /api/rules/{host}", s.getRuleByHost)
	mux.HandleFunc("PUT /api/rules", s.putRule)
	mux.HandleFunc("DELETE /api/rules/{id}", s.deleteRule)

	// tiers (failover chain — sub-resource of a target, keyed by target id)
	mux.HandleFunc("GET /api/tiers/{targetID}", s.listTiers)
	mux.HandleFunc("PUT /api/tiers", s.putTier)
	mux.HandleFunc("DELETE /api/tiers/{targetID}/{tier}", s.deleteTier)

	// users
	mux.HandleFunc("GET /api/users", s.listUsers)
	mux.HandleFunc("PUT /api/users", s.putUser)

	// live + observability + PAC
	mux.HandleFunc("GET /events", s.events)
	// /metrics is ALSO on this mTLS mux, so a cert-bearing scraper can always read it
	// on the control port (fail-closed, never a silent plaintext leak). For the
	// common case where Prometheus does NOT do mTLS, the server can ADDITIONALLY
	// expose /metrics over plain HTTP on a SEPARATE address via CONTROL_API_METRICS_ADDR
	// (Config.MetricsAddr → startMetricsListener); that listener serves ONLY /metrics
	// (never this CRUD/SSE/PAC surface) and is OFF by default (empty ⇒ mTLS-only,
	// zero behaviour change, §11.4.122). Its bind address is security-load-bearing —
	// see Config.MetricsAddr + startMetricsListener.
	mux.Handle("GET /metrics", s.metrics.handler())
	mux.HandleFunc("GET /proxy.pac", s.proxyPAC)

	return mux
}

// metricsRoutes wires a SEPARATE mux that serves ONLY the Prometheus /metrics
// endpoint — never the CRUD/SSE/PAC control surface. It is the handler for the
// optional plaintext metrics listener (cfg.MetricsAddr): a scraper reaches /metrics
// over plain HTTP without a client cert, while every mutating path returns 404.
func (s *server) metricsRoutes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", s.metrics.handler())
	return mux
}

// boundMetricsAddr reports the address the plaintext metrics listener actually
// bound ("" when the feature is off or not yet bound). It reads the same registry
// state startMetricsListener writes, so tests + operators can observe the port even
// when cfg.MetricsAddr used an ephemeral ":0".
func (s *server) boundMetricsAddr() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.metricsAddr
}

// startMetricsListener binds cfg.MetricsAddr and serves ONLY /metrics over plain
// HTTP. When MetricsAddr is EMPTY the feature is OFF: it returns (nil, "", nil) and
// the caller adds no listener — ZERO behaviour change, the mTLS server stays the
// only socket (§11.4.122). A bind failure is returned as an error (fail-closed on a
// misconfigured metrics address — never a silent no-op). On success it records the
// bound address (observable via boundMetricsAddr) and serves in a background
// goroutine that returns when the caller Shutdown()s the returned *http.Server.
func (s *server) startMetricsListener() (*http.Server, string, error) {
	if s.cfg.MetricsAddr == "" {
		return nil, "", nil
	}
	ln, err := net.Listen("tcp", s.cfg.MetricsAddr)
	if err != nil {
		return nil, "", fmt.Errorf("api: bind plaintext metrics listener %q: %w", s.cfg.MetricsAddr, err)
	}
	addr := ln.Addr().String()
	hs := &http.Server{
		Handler:           s.metricsRoutes(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	s.mu.Lock()
	s.metricsAddr = addr
	s.mu.Unlock()
	go func() {
		// hs.Serve returns ErrServerClosed on a clean Shutdown; any other error is a
		// real post-bind failure worth surfacing (the bind error itself was already
		// returned synchronously above, so this never hides a startup problem).
		if serveErr := hs.Serve(ln); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			fmt.Fprintf(os.Stderr, "api: plaintext metrics listener on %s stopped: %v\n", addr, serveErr)
		}
	}()
	return hs, addr, nil
}

// Start serves over mTLS and blocks until ctx is cancelled (then it drains with a
// short timeout) or the listener errors. The TLS config REQUIRES a verified client
// cert (tls.go) — there is no plaintext fallback (fail-closed, spec §10/§12).
//
// When cfg.MetricsAddr is set, Start ALSO brings up the optional plaintext /metrics
// listener (startMetricsListener) and drains it on the SAME signal path — the
// deferred Shutdown fires on every Start return (ctx cancel OR mTLS error), so the
// extra listener never outlives the server (no goroutine/socket leak). It is OFF by
// default (empty MetricsAddr), leaving the mTLS server as the sole listener.
func (s *server) Start(ctx context.Context) error {
	tlsCfg, err := buildTLSConfig(s.cfg)
	if err != nil {
		return err
	}

	metricsSrv, metricsAddr, err := s.startMetricsListener()
	if err != nil {
		return err
	}
	if metricsSrv != nil {
		fmt.Fprintf(os.Stderr, "api: serving PLAINTEXT /metrics on %s (no mTLS; separate scrape target)\n", metricsAddr)
		defer func() {
			shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = metricsSrv.Shutdown(shutCtx)
		}()
	}

	hs := &http.Server{
		Addr:              s.cfg.Addr,
		Handler:           s.mux,
		TLSConfig:         tlsCfg,
		ReadHeaderTimeout: 10 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		// Certs are already in TLSConfig, so the file args are empty.
		errCh <- hs.ListenAndServeTLS("", "")
	}()

	select {
	case <-ctx.Done():
		shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return hs.Shutdown(shutCtx)
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}
