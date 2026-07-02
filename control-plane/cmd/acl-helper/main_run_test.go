// Hermetic unit tests for the two startup/entry branches the protocol-loop tests
// in main_unit_test.go do not reach: run()'s fail-closed Redis-connect error path
// and main()'s -version short-circuit. Both are deterministic and network-free
// (a just-closed local port gives an immediate connection-refused, a fresh flag
// set + os.Stdout capture drive -version in-process) — no live Redis, no signals,
// no os.Exit. run()'s SUCCESS path and main()'s os.Exit(1) path require a real
// Redis and belong to the child-process integration test (integration_test.go).
package main

import (
	"context"
	"flag"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// closedLocalAddr returns a 127.0.0.1:<port> whose listener was just closed, so a
// dial to it is refused immediately (no server) — the deterministic, Redis-free
// connection-refused technique used across internal/redis fail-closed tests.
func closedLocalAddr(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := l.Addr().String()
	if err := l.Close(); err != nil {
		t.Fatalf("close listener: %v", err)
	}
	return addr
}

// TestRun_RedisUnreachableFailsClosed proves run()'s startup fail-closed contract:
// when redis.Open cannot reach REDIS_ADDR, run() returns a non-nil error naming the
// address (never a nil error with a dead bus) AND serves NOTHING on stdout. Regression
// caught: if the `if err != nil { return ... }` after redis.Open were removed or its
// error swallowed, run() would build a Decider over a broken bus and start serving —
// a fail-OPEN startup leak. The empty-stdout assertion proves no request was answered.
func TestRun_RedisUnreachableFailsClosed(t *testing.T) {
	addr := closedLocalAddr(t)
	t.Setenv("REDIS_ADDR", addr)
	t.Setenv("REDIS_DIAL_TIMEOUT", "1s") // connection-refused is immediate; bounds the worst case
	// Clear the other knobs so defaults apply regardless of the host environment.
	t.Setenv("REDIS_STATUS_MAX_AGE", "")
	t.Setenv("ACL_REQUEST_TIMEOUT", "")

	inR, inW, err := os.Pipe()
	if err != nil {
		t.Fatalf("in pipe: %v", err)
	}
	defer func() { _ = inR.Close(); _ = inW.Close() }()
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatalf("out pipe: %v", err)
	}
	defer func() { _ = outR.Close(); _ = outW.Close() }()

	// A request is waiting on stdin; a fail-OPEN regression would read + answer it.
	if _, err := io.WriteString(inW, "up-host\n"); err != nil {
		t.Fatalf("seed stdin: %v", err)
	}
	_ = inW.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	runErr := run(ctx, inR, outW)
	_ = outW.Close()

	if runErr == nil {
		t.Fatal("run() with unreachable Redis returned nil; startup must fail closed with an error")
	}
	if !strings.Contains(runErr.Error(), "connect redis") {
		t.Errorf("run() error = %q, want it to name the connect-redis failure", runErr.Error())
	}
	if !strings.Contains(runErr.Error(), addr) {
		t.Errorf("run() error = %q, want it to include the unreachable address %q", runErr.Error(), addr)
	}

	out, err := io.ReadAll(outR)
	if err != nil {
		t.Fatalf("read stdout: %v", err)
	}
	if len(out) != 0 {
		t.Errorf("fail-closed startup served %q on stdout, want nothing (no request answered)", out)
	}
}

// TestRun_TightDialTimeoutFailsClosed exercises the same error path via an
// unroutable address bounded by a short REDIS_DIAL_TIMEOUT rather than an instant
// refusal, proving the dial-timeout wiring (context.WithTimeout(ctx, dialTimeout))
// also resolves to the startup error and not a hang. Regression caught: dropping the
// dialCtx timeout would let a black-hole address hang startup indefinitely.
func TestRun_TightDialTimeoutFailsClosed(t *testing.T) {
	// 192.0.2.0/24 (TEST-NET-1, RFC 5737) is reserved + non-routable: a dial there
	// neither connects nor refuses, so only the dial timeout can end it.
	t.Setenv("REDIS_ADDR", "192.0.2.1:6379")
	t.Setenv("REDIS_DIAL_TIMEOUT", "200ms")
	t.Setenv("REDIS_STATUS_MAX_AGE", "")
	t.Setenv("ACL_REQUEST_TIMEOUT", "")

	inR, inW, err := os.Pipe()
	if err != nil {
		t.Fatalf("in pipe: %v", err)
	}
	defer func() { _ = inR.Close(); _ = inW.Close() }()
	_ = inW.Close()
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatalf("out pipe: %v", err)
	}
	defer func() { _ = outR.Close(); _ = outW.Close() }()

	// The parent ctx is generous; the SHORT REDIS_DIAL_TIMEOUT must be what ends it.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	start := time.Now()
	runErr := run(ctx, inR, outW)
	elapsed := time.Since(start)
	_ = outW.Close()

	if runErr == nil {
		t.Fatal("run() against a non-routable address returned nil; must fail closed on dial timeout")
	}
	if !strings.Contains(runErr.Error(), "connect redis") {
		t.Errorf("run() error = %q, want a connect-redis failure", runErr.Error())
	}
	// The dial timeout is 200ms; ending well before the 10s parent ctx proves the
	// dialCtx timeout (not the parent ctx) bounded the dial.
	if elapsed >= 5*time.Second {
		t.Errorf("run() took %v; the 200ms dial timeout should end it far sooner", elapsed)
	}
}

// TestMain_VersionFlag proves main()'s -version short-circuit: it prints
// "acl-helper <version>" to stdout and returns WITHOUT connecting to Redis or
// calling os.Exit. Driven in-process with a fresh flag.FlagSet (so the -version
// flag and the test binary's -test.* flags do not collide) and captured os.Stdout.
// Regression caught: breaking the `if *showVersion { ... return }` guard would make
// -version fall through into run() (a Redis dial) or print the wrong string.
func TestMain_VersionFlag(t *testing.T) {
	// Swap in a throwaway flag set + args, restore on cleanup.
	origArgs := os.Args
	origCL := flag.CommandLine
	origStdout := os.Stdout
	t.Cleanup(func() {
		os.Args = origArgs
		flag.CommandLine = origCL
		os.Stdout = origStdout
	})
	flag.CommandLine = flag.NewFlagSet(origArgs[0], flag.ContinueOnError)
	os.Args = []string{"acl-helper", "-version"}

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	os.Stdout = w
	done := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(r)
		done <- string(b)
	}()

	// main() must return here (the -version branch); if it fell through to run() it
	// would block on a Redis dial and this test would time out — itself a failure.
	main()

	_ = w.Close()
	os.Stdout = origStdout
	got := strings.TrimRight(<-done, "\n")

	want := "acl-helper " + version
	if got != want {
		t.Errorf("main -version printed %q, want %q", got, want)
	}
}

// TestVersionConstantShape guards the version identifier's shape so a fat-fingered
// edit (empty string, stray whitespace) is caught rather than silently shipped in
// the -version reply operators read. Deliberately loose: it asserts non-empty and
// trimmed, not a specific value, so a legitimate version bump does not break it.
func TestVersionConstantShape(t *testing.T) {
	if strings.TrimSpace(version) == "" {
		t.Fatal("version constant is empty/whitespace")
	}
	if version != strings.TrimSpace(version) {
		t.Errorf("version %q has surrounding whitespace", version)
	}
	// Sanity: the reply main() emits is parseable back into a non-empty token.
	fields := strings.Fields("acl-helper " + version)
	if len(fields) < 2 {
		t.Errorf("version reply %q does not split into name+version", "acl-helper "+version)
	}
	// Keep strconv imported for use if the version scheme ever needs numeric checks;
	// assert the leading numeric component parses to catch a non-numeric first segment.
	lead := strings.SplitN(version, ".", 2)[0]
	if _, err := strconv.Atoi(lead); err != nil {
		t.Errorf("version %q leading segment %q is not numeric", version, lead)
	}
}
