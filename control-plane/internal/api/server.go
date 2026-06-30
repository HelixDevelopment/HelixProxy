// Concrete control-API server (design spec §4 component 4, §11 ③⑤⑥). It serves
// REST CRUD over the store, the SSE live-event stream, the Prometheus /metrics
// endpoint, and the PAC file — all over mTLS (tls.go). The byte path stays out of
// the control plane: this server reads/writes the data model + the live status
// bus; the proxies route per request via the acl-helper + Redis (spec §8/§9).
package api

import (
	"context"
	"errors"
	"net/http"
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
	// WARNING-5 (P6 review — design note, deferred to operator/P10, NOT a code
	// change here): /metrics is on THIS mux, which Start() serves ONLY over the
	// fail-closed mTLS listener (tls.go, RequireAndVerifyClientCert). So Prometheus
	// can scrape /metrics ONLY with a valid client cert. The committed scrape config
	// (config/prometheus/prometheus.yml, job helix-control-plane) instead expects a
	// PLAINTEXT scrape of proxy-control-plane:59090 (METRICS_PORT) with no tls_config
	// — i.e. the intended topology is a SEPARATE plaintext metrics listener on
	// METRICS_PORT, distinct from the mTLS control-API port (CONTROL_API_*, :58080/1).
	// Trade-off: (a) mTLS-only (current) — no plaintext surface, but Prometheus must
	// be provisioned with a client cert and it diverges from prometheus.yml; (b) a
	// separate plaintext metrics listener — matches prometheus.yml + standard
	// practice, but its bind address is security-load-bearing: loopback-only
	// (127.0.0.1:59090) is safe yet UNREACHABLE for a Prometheus in another
	// container/pod (the prometheus.yml target is the service hostname
	// proxy-control-plane:59090, needing a pod-network/0.0.0.0 bind), while a
	// 0.0.0.0 bind exposes unauthenticated metrics to the whole compose/pod network
	// (acceptable ONLY if that network is the trust boundary). RECOMMENDATION
	// (§11.4.6/§11.4.101 — operator/P10 owns the compose networking): add a separate
	// plaintext listener on a configurable CONTROL_API_METRICS_ADDR (default
	// 127.0.0.1:59090) serving ONLY this /metrics handler (never CRUD/SSE/PAC), bound
	// to the pod-internal interface. NOT implemented here: it adds a second socket +
	// lifecycle + config field whose correct bind depends on the (P10-owned)
	// deployment topology — forcing loopback-only now would break the committed
	// cross-container scrape, and forcing 0.0.0.0 now would be a security-exposure
	// decision only the operator can make. Until then /metrics stays mTLS-only and a
	// cert-bearing scraper can read it (fail-closed, never a silent plaintext leak).
	mux.Handle("GET /metrics", s.metrics.handler())
	mux.HandleFunc("GET /proxy.pac", s.proxyPAC)

	return mux
}

// Start serves over mTLS and blocks until ctx is cancelled (then it drains with a
// short timeout) or the listener errors. The TLS config REQUIRES a verified client
// cert (tls.go) — there is no plaintext fallback (fail-closed, spec §10/§12).
func (s *server) Start(ctx context.Context) error {
	tlsCfg, err := buildTLSConfig(s.cfg)
	if err != nil {
		return err
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
