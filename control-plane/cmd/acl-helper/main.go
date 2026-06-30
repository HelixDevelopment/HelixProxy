// Command acl-helper is the Squid external_acl_type helper (design spec §4
// component 3, docs/DYNAMIC_ROUTING.md §3.1/§4). For each request Squid passes
// the request Host on stdin; the helper reads Redis (route:<target> +
// vpn:status:<tunnel>) and writes `OK tag=<tunnel>` (route this request to that
// tunnel's cache_peer) or `ERR` (Squid turns ERR into deny_info 503
// ERR_TUNNEL_DOWN) on stdout — one reply per line. It is OUT of the byte path
// and fails closed: any miss / down / Redis error / malformed input yields ERR,
// never a leak.
//
// Protocol framing (serial OR Squid `concurrency=N` channel-id) and the pure
// fail-closed verdict live in internal/aclhelper. The circuit-breaker tunnel
// tier-failover is a SEPARATE later stream (P5b) and is intentionally NOT wired
// here. Dependencies: stdlib + the committed internal/redis only.
//
// Environment:
//
//	REDIS_ADDR            Redis address (default 127.0.0.1:6379).
//	REDIS_STATUS_MAX_AGE  Optional freshness window for vpn:status (Go duration,
//	                      e.g. 10s). Unset/<=0 ⇒ TTL-only fail-closed (the
//	                      committed client already treats a missing/expired key
//	                      as DOWN); this is defence-in-depth, not the primary gate.
//	REDIS_DIAL_TIMEOUT    Startup PING timeout (Go duration, default 5s).
//	ACL_REQUEST_TIMEOUT   Per-request Redis lookup timeout (default 2s); a lookup
//	                      that exceeds it fails closed (ERR).
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/aclhelper"
	"digital.vasic.helixproxy/controlplane/internal/redis"
)

const version = "0.1.0-p5"

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("acl-helper", version)
		return
	}

	// SIGTERM/SIGINT cancel the root context for a clean shutdown; stdin EOF
	// (Squid closing the pipe on reconfigure/stop) ends the loop the same way.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if err := run(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "acl-helper:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, in *os.File, out *os.File) error {
	addr := envOr("REDIS_ADDR", "127.0.0.1:6379")
	maxAge := envDuration("REDIS_STATUS_MAX_AGE", 0)
	dialTimeout := envDuration("REDIS_DIAL_TIMEOUT", 5*time.Second)
	reqTimeout := envDuration("ACL_REQUEST_TIMEOUT", 2*time.Second)

	dialCtx, cancel := context.WithTimeout(ctx, dialTimeout)
	defer cancel()
	bus, err := redis.Open(dialCtx, addr, maxAge)
	if err != nil {
		return fmt.Errorf("connect redis %s: %w", addr, err)
	}
	defer func() { _ = bus.Close() }()

	dec := aclhelper.Decider{Bus: bus}
	return loop(ctx, dec, in, out, reqTimeout)
}

// loop reads request lines from in, writes one reply line per request to out,
// flushing after each so Squid never blocks waiting on a buffered reply. It
// returns on stdin EOF or ctx cancellation. A read error other than EOF is
// surfaced; everything about a single request fails closed to ERR.
func loop(ctx context.Context, dec aclhelper.Decider, in *os.File, out *os.File, reqTimeout time.Duration) error {
	r := bufio.NewReader(in)
	w := bufio.NewWriter(out)
	defer func() { _ = w.Flush() }()

	for {
		if ctx.Err() != nil {
			return nil
		}
		line, err := r.ReadString('\n')
		if len(line) > 0 {
			req := aclhelper.ParseLine(line)
			ok, tag := decideWithTimeout(ctx, dec, req.Host, reqTimeout)
			if _, werr := w.WriteString(aclhelper.FormatReply(req.Channel, ok, tag)); werr != nil {
				return fmt.Errorf("write reply: %w", werr)
			}
			if ferr := w.Flush(); ferr != nil {
				return fmt.Errorf("flush reply: %w", ferr)
			}
		}
		if err != nil {
			// io.EOF (stdin closed) is a clean shutdown; any other read error
			// ends the loop too (Squid will respawn the helper).
			return nil
		}
	}
}

// decideWithTimeout bounds each Redis lookup so a hung Redis fails closed (ERR)
// instead of blocking the helper. An empty host short-circuits to ERR without
// touching Redis.
func decideWithTimeout(ctx context.Context, dec aclhelper.Decider, host string, timeout time.Duration) (bool, string) {
	if host == "" {
		return false, ""
	}
	rctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return dec.Decide(rctx, host)
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}
