// Command healthd is the vpn-health-publisher (design spec §4 component 1, §5,
// §7; plan Phase 3). Per profile it polls the gluetun control API
// (/v1/vpn/status, /v1/publicip/ip), reads the `wg show <if> transfer` byte-delta
// and the latest WireGuard handshake, then runs the PURE vpn.DecideHealth verdict
// and writes vpn:status:<profile> (with a TTL) via the committed redis client,
// publishing vpn:events ONLY on a state transition.
//
// Health is a DATA-PLANE FACT, never "configured" (§11.4.107 / §11.4.69): a
// "running" control-API status with an EMPTY public_ip (no real egress) or a flat
// tx counter is reported DOWN (fail-closed). Stdlib only beyond the committed
// internal packages.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/otel"
	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

const version = "0.1.0-phase3"

// sampler gathers the raw data-plane facts for one profile (egress IP, rx/tx,
// latest handshake) and stamps CheckedAt. It does NOT decide up/down — that is
// vpn.DecideHealth's job. A sampling error is reported by the caller as DOWN
// (fail-closed); the sampler never fabricates counters.
type sampler interface {
	sample(ctx context.Context, profile string) (vpn.HealthSnapshot, error)
}

// statusPublisher is the subset of the committed redis.Client healthd needs.
// *redis.Client satisfies it (compile-time checked in run()).
type statusPublisher interface {
	SetStatus(ctx context.Context, snap vpn.HealthSnapshot, ttlSeconds int) error
	PublishEvent(ctx context.Context, e redis.Event) error
}

// liveSampler combines a gluetun control client (egress IP) with a wg reader
// (rx/tx + handshake). wg failures (binary missing / interface absent / no
// privilege) leave the byte counters and handshake at zero → DecideHealth fails
// closed (DOWN), which is the correct, honest verdict.
type liveSampler struct {
	ctrl   *vpn.ControlClient
	wg     vpn.WGReader
	ifName string
}

func (s liveSampler) sample(ctx context.Context, profile string) (vpn.HealthSnapshot, error) {
	now := time.Now().UTC()
	snap := vpn.HealthSnapshot{Profile: profile, CheckedAt: now}

	// Egress IP is the load-bearing fact. An unreachable gluetun is the only
	// sample-level failure (caller → fresh DOWN). A reachable gluetun reporting
	// an EMPTY egress is NOT an error — it is a real reading that DecideHealth
	// turns into DOWN (the fail-closed "no real egress" path).
	egress, err := s.ctrl.EgressIP(ctx, profile)
	if err != nil {
		return snap, err
	}
	snap.EgressIP = egress

	// Byte counters + handshake from wg are best-effort: a wg error (binary or
	// interface absent) leaves them zero so DecideHealth fails closed (no
	// tx-delta / no handshake) WITHOUT masking the egress reading above.
	if rx, tx, latest, werr := s.wg.Sample(ctx, s.ifName); werr == nil {
		snap.Rx, snap.Tx, snap.LastHandshake = rx, tx, latest
	} else {
		fmt.Fprintf(os.Stderr, "healthd[%s]: wg sample (%s): %v\n", profile, s.ifName, werr)
	}
	return snap, nil
}

// pollOnce performs one sample → decide cycle for a profile. A sampling error is
// turned into a fresh DOWN snapshot (CheckedAt set so the published key stays
// fresh while the tunnel is unreachable). prev supplies the tx-delta baseline.
func pollOnce(ctx context.Context, profile string, s sampler, eval vpn.HealthEvaluator, prev vpn.HealthSnapshot, hostIP string) vpn.HealthSnapshot {
	cur, err := s.sample(ctx, profile)
	if err != nil {
		// Fail-closed: report DOWN with a fresh timestamp, no fabricated counters.
		return vpn.HealthSnapshot{Profile: profile, State: vpn.StateDown, CheckedAt: time.Now().UTC()}
	}
	cur.State = eval.Evaluate(prev, cur, hostIP)
	return cur
}

// runProfile runs the per-profile poll loop until ctx is cancelled. It writes
// every snapshot (so the TTL stays fresh) and publishes vpn:events ONLY when the
// reported state changes from the previously-reported state.
func runProfile(ctx context.Context, c config, profile string, s sampler, eval vpn.HealthEvaluator, pub statusPublisher) {
	var prev vpn.HealthSnapshot // tx-delta baseline (cumulative counters)
	lastReported := vpn.StateUnknown
	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()

	tick := func() {
		cctx, cancel := context.WithTimeout(ctx, c.interval)
		defer cancel()
		cur := pollOnce(cctx, profile, s, eval, prev, c.hostIP)

		if err := pub.SetStatus(cctx, cur, c.ttlSeconds); err != nil {
			fmt.Fprintf(os.Stderr, "healthd[%s]: SetStatus: %v\n", profile, err)
		}
		if cur.State != lastReported {
			if err := pub.PublishEvent(cctx, redis.Event{ProfileID: profile, State: cur.State}); err != nil {
				fmt.Fprintf(os.Stderr, "healthd[%s]: PublishEvent: %v\n", profile, err)
			} else {
				fmt.Fprintf(os.Stderr, "healthd[%s]: %s → %s (egress=%q tx=%d)\n", profile, lastReported, cur.State, cur.EgressIP, cur.Tx)
			}
			lastReported = cur.State
		}
		// Advance the baseline only on a successful sample (cur carries counters).
		if cur.State == vpn.StateUp || cur.Tx > 0 || !cur.LastHandshake.IsZero() {
			prev = cur
		}
	}

	tick() // first poll immediately (don't wait a full interval)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			tick()
		}
	}
}

// config is the env-driven runtime configuration.
type config struct {
	redisAddr   string
	profiles    []string
	gluetunBase func(profile string) string
	wgIf        func(profile string) string
	interval    time.Duration
	freshness   time.Duration
	ttlSeconds  int
	hostIP      string
	maxAge      time.Duration
}

func loadConfig() config {
	getenv := func(k, def string) string {
		if v := os.Getenv(k); v != "" {
			return v
		}
		return def
	}
	c := config{
		redisAddr: getenv("REDIS_ADDR", "127.0.0.1:6379"),
		hostIP:    os.Getenv("HEALTHD_HOST_IP"),
	}
	c.profiles = splitCSV(getenv("HEALTHD_PROFILES", "demo"))
	port := getenv("GLUETUN_CONTROL_PORT", "8000")
	baseDefault := getenv("HEALTHD_GLUETUN_BASE", "http://127.0.0.1:"+port)
	c.gluetunBase = func(profile string) string {
		if v := os.Getenv("HEALTHD_GLUETUN_BASE_" + envKey(profile)); v != "" {
			return v
		}
		return baseDefault
	}
	c.wgIf = func(profile string) string {
		if v := os.Getenv("HEALTHD_WG_IF_" + envKey(profile)); v != "" {
			return v
		}
		if v := os.Getenv("HEALTHD_WG_IF"); v != "" {
			return v
		}
		return profile // default: interface name == profile name
	}
	c.interval = parseDuration(getenv("HEALTHD_POLL_INTERVAL", "5s"), 5*time.Second)
	c.freshness = parseDuration(getenv("HEALTHD_FRESHNESS", "180s"), 180*time.Second)
	if v, err := strconv.Atoi(os.Getenv("HEALTHD_TTL_SECONDS")); err == nil && v > 0 {
		c.ttlSeconds = v
	} else {
		// Default: 3 poll intervals so a missed poll expires the key (fail-closed).
		c.ttlSeconds = int(3 * c.interval.Seconds())
		if c.ttlSeconds < 1 {
			c.ttlSeconds = 1
		}
	}
	c.maxAge = parseDuration(getenv("HEALTHD_REDIS_MAXAGE", "60s"), 60*time.Second)
	return c
}

func splitCSV(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// envKey upper-cases a profile name into the env-var suffix form (a-z0-9 → A-Z0-9,
// everything else → '_'), so profile "nordvpn-uk" → "NORDVPN_UK".
func envKey(profile string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(profile) {
		switch {
		case r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	return b.String()
}

func parseDuration(s string, def time.Duration) time.Duration {
	if d, err := time.ParseDuration(s); err == nil && d > 0 {
		return d
	}
	return def
}

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("healthd", version)
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	shutdown, _ := otel.Init(ctx, "healthd")
	defer func() { _ = shutdown(context.Background()) }()

	if err := run(ctx, loadConfig()); err != nil {
		fmt.Fprintln(os.Stderr, "healthd:", err)
		os.Exit(1)
	}
}

// run opens Redis and launches one poll goroutine per profile, returning when ctx
// is cancelled (graceful shutdown).
func run(ctx context.Context, c config) error {
	openCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rc, err := redis.Open(openCtx, c.redisAddr, c.maxAge)
	if err != nil {
		return fmt.Errorf("open redis %s: %w", c.redisAddr, err)
	}
	defer func() { _ = rc.Close() }()
	var pub statusPublisher = rc // compile-time check *redis.Client satisfies it

	eval := vpn.DataPlaneEvaluator{Freshness: c.freshness}
	fmt.Fprintf(os.Stderr, "healthd %s: profiles=%v interval=%s freshness=%s ttl=%ds redis=%s\n",
		version, c.profiles, c.interval, c.freshness, c.ttlSeconds, c.redisAddr)

	var wg sync.WaitGroup
	for _, profile := range c.profiles {
		s := liveSampler{
			ctrl:   vpn.NewControlClient(c.gluetunBase(profile)),
			wg:     vpn.WGReader{},
			ifName: c.wgIf(profile),
		}
		wg.Add(1)
		go func(p string, smp sampler) {
			defer wg.Done()
			runProfile(ctx, c, p, smp, eval, pub)
		}(profile, s)
	}
	<-ctx.Done()
	wg.Wait()
	return nil
}
