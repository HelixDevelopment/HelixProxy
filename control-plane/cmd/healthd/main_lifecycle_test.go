// Hermetic unit tests for the healthd BINARY's process-lifecycle branches that the
// loop / live-sampler / config tests do not reach and the podman integration test
// only covers when it runs (it SKIPs without podman, leaving run() + main() at 0%):
// run()'s fail-closed "cannot reach the status bus ⇒ refuse to start" guard, and
// main()'s -version short-circuit (returns BEFORE touching any backend). Both are
// driven with NO real Redis, NO gluetun, NO network, NO containers — an
// already-cancelled context makes redis.Open's PING fail immediately (no socket is
// ever dialled, proven by the elapsed guard), and -version returns cleanly. Each
// assertion pins genuine behaviour: dropping the error wrap, the address in the
// message, or the version short-circuit makes a test FAIL (§11.4.1 no FAIL-bluff,
// §11.4.115). Run under -short.
package main

import (
	"context"
	"flag"
	"os"
	"strings"
	"testing"
	"time"
)

// captureStdout runs fn with os.Stdout redirected to a pipe and returns what fn
// printed — used to assert main()'s user-facing output on the -version short-circuit.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	orig := os.Stdout
	os.Stdout = w
	defer func() { os.Stdout = orig }()

	fn()

	_ = w.Close()
	buf := make([]byte, 0, 512)
	tmp := make([]byte, 256)
	for {
		n, rerr := r.Read(tmp)
		buf = append(buf, tmp[:n]...)
		if rerr != nil {
			break
		}
	}
	_ = r.Close()
	return string(buf)
}

// run must fail closed when the status bus is unreachable: redis.Open PINGs on
// open, so it is the FIRST thing run() does (unlike a control surface that could
// come up degraded). Feeding an ALREADY-cancelled context makes the PING return
// context.Canceled immediately — no TCP connection is ever attempted — and run()
// MUST return the error wrapped as "open redis <addr>: ...". A missing status bus
// means healthd would publish nothing (silent DOWN-blindness), so refusing to
// start is the correct fail-closed contract (§11.4.107 / §11.4.69).
//
// Regression guards: (1) if the redis error is swallowed / not returned, err is
// nil and the test FAILs; (2) if the wrap prefix is dropped, the "open redis "
// prefix assertion FAILs; (3) if the %s address is removed from the message, the
// addr-substring assertion FAILs; (4) if a regression turns the cancelled-context
// path into a real (slow) dial against the 5s openCtx budget, the elapsed guard
// FAILs — proving the test stays hermetic.
func TestRun_RedisUnreachableFailsClosed(t *testing.T) {
	const addr = "203.0.113.7:6379" // TEST-NET-3 (RFC 5737); never dialled here.
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled ⇒ redis.Open's PING fails before any socket work.

	c := config{
		redisAddr:  addr,
		profiles:   []string{"demo"},
		interval:   time.Second,
		freshness:  time.Second,
		ttlSeconds: 1,
		maxAge:     time.Second,
	}

	start := time.Now()
	err := run(ctx, c)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("run(unreachable bus) = nil, want a fail-closed open-redis error")
	}
	if !strings.HasPrefix(err.Error(), "open redis ") {
		t.Errorf("run err = %q, want it to start with %q", err, "open redis ")
	}
	if !strings.Contains(err.Error(), addr) {
		t.Errorf("run err = %q, want it to name the redis address %q", err, addr)
	}
	// Hermeticity proof: a cancelled-context PING returns instantly; a genuine dial
	// would burn seconds against the 5s openCtx. Guard against a non-hermetic regression.
	if elapsed > 3*time.Second {
		t.Errorf("run(unreachable bus) took %v, want an instant cancelled-context error (no dial)", elapsed)
	}
}

// main() with -version prints "healthd <version>" to stdout and returns WITHOUT
// opening Redis or launching any poll goroutine. Regression guard: removing the
// -version short-circuit makes main() fall through to signal setup → run() →
// redis.Open against 127.0.0.1:6379 → (no bus) os.Exit(1), which would abort the
// test process; the presence of the version line proves the short-circuit fired
// and nothing downstream ran.
//
// main() registers its flags on the process-global flag.CommandLine; a fresh
// FlagSet is swapped in (and os.Args set) for the duration of the call and both are
// restored afterwards, so the test is idempotent under -count=N (§11.4.50) — a
// second invocation would otherwise panic "flag redefined: version" — and leaves
// no global state for sibling tests.
func TestMain_VersionShortCircuits(t *testing.T) {
	origArgs := os.Args
	origFlags := flag.CommandLine
	defer func() { os.Args = origArgs; flag.CommandLine = origFlags }()
	os.Args = []string{"healthd", "-version"}
	flag.CommandLine = flag.NewFlagSet("healthd", flag.ContinueOnError)

	out := captureStdout(t, func() { main() })

	if !strings.Contains(out, "healthd "+version) {
		t.Errorf("main(-version) stdout = %q, want it to contain %q", out, "healthd "+version)
	}
}
