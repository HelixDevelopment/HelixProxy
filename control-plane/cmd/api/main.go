// Command api is the control-plane REST API server (design spec §4 component 4,
// §11 ③⑤⑥, plan Phase 6): CRUD over profiles/targets/rules/tiers/users, live
// status via SSE, a Prometheus /metrics endpoint, the FindProxyForURL PAC
// endpoint, all over mTLS. It replaces the traefik/whoami placeholder.
//
// Wiring: a real Postgres store (HELIX_PG_DSN) + the fail-closed Redis status bus
// (REDIS_ADDR) + the PAC generator back an api.Server served over mTLS. The
// cert/key/client-CA come from FILE PATHS (the Podman-secret mount points named by
// CONTROL_API_TLS_CERT / CONTROL_API_TLS_KEY / CONTROL_API_TLS_CLIENT_CA) — never
// embedded key material (§11.4.10). The listen address is CONTROL_API_ADDR
// (default :58080). The server fails closed: it refuses to start without its
// backends and without a verified-client-cert TLS config.
//
// OPTIONAL plaintext metrics: when CONTROL_API_METRICS_ADDR is set, the server ALSO
// exposes /metrics over plain HTTP on that SEPARATE address (Prometheus scrapers
// rarely present a client cert). It serves ONLY /metrics — the mutating control
// surface stays on the mTLS port. Empty ⇒ OFF (mTLS-only, zero behaviour change).
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/api"
	"digital.vasic.helixproxy/controlplane/internal/otel"
	"digital.vasic.helixproxy/controlplane/internal/pac"
	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/store"
)

const version = "0.1.0"

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	addr := flag.String("addr", getenv("CONTROL_API_ADDR", ":58080"), "control-API listen address")
	flag.Parse()
	if *showVersion {
		fmt.Println("api", version)
		return
	}
	if err := run(*addr); err != nil {
		fmt.Fprintln(os.Stderr, "api:", err)
		os.Exit(1)
	}
}

func run(addr string) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdown, _ := otel.Init(ctx, "api")
	defer func() { _ = shutdown(context.Background()) }()

	dsn := os.Getenv("HELIX_PG_DSN")
	if dsn == "" {
		return fmt.Errorf("$HELIX_PG_DSN is required")
	}
	openCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	pg, err := store.Open(openCtx, dsn)
	if err != nil {
		return fmt.Errorf("open postgres: %w", err)
	}
	defer func() { _ = pg.Close() }()

	bus, err := redis.Open(openCtx, getenv("REDIS_ADDR", "127.0.0.1:6379"), 60*time.Second)
	if err != nil {
		return fmt.Errorf("open redis: %w", err)
	}
	defer func() { _ = bus.Close() }()

	cfg := api.Config{
		Addr:     addr,
		TLSCert:  os.Getenv("CONTROL_API_TLS_CERT"),
		TLSKey:   os.Getenv("CONTROL_API_TLS_KEY"),
		ClientCA: os.Getenv("CONTROL_API_TLS_CLIENT_CA"),
		// Optional SEPARATE plaintext /metrics listener (Prometheus rarely does mTLS).
		// Empty ⇒ OFF: the mTLS server is the only listener, zero behaviour change
		// (§11.4.122). When set, /metrics is ALSO served over plain HTTP here, while
		// the mutating control surface stays on the fail-closed mTLS port unchanged.
		MetricsAddr: os.Getenv("CONTROL_API_METRICS_ADDR"),
	}
	srv := api.NewServer(cfg, pg, bus, pac.NewGenerator())

	fmt.Fprintf(os.Stderr, "api %s: serving mTLS control-API on %s\n", version, addr)
	return srv.Start(ctx)
}
