// Unit tests (no live database, no Redis, no containers, no network) for the api
// BINARY's env helper + fail-closed argument/backends branches. The full mTLS
// control-API path against real Postgres + Redis is proven by the integration
// layer; these tests deterministically exercise the branches that DO NOT need a
// data plane — the getenv default/override helper, run()'s empty-$HELIX_PG_DSN
// guard (fails closed BEFORE opening anything), the store.Open error wrap (via a
// MALFORMED DSN → a pure pgx parse error, no socket is ever opened), and main()'s
// -version short-circuit. Each assertion pins genuine behaviour: flipping a
// guarded branch to success, dropping an error wrap, or removing the version
// short-circuit makes a test FAIL (§11.4.1 no FAIL-bluff, §11.4.115).
package main

import (
	"flag"
	"os"
	"strings"
	"testing"
	"time"
)

// captureStdout runs fn with os.Stdout redirected to a pipe and returns what fn
// printed. Used to assert main()'s user-facing output on the version short-circuit.
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

// getenv returns the env value when set-and-non-empty, else the default. Both
// branches pinned. Regression guard: swapping the branch (returning def on set, or
// value on unset) makes one of the two cases FAIL.
func TestGetenv(t *testing.T) {
	const key = "HELIX_API_UNIT_GETENV_PROBE"
	tests := []struct {
		name    string
		set     bool
		value   string
		def     string
		want    string
	}{
		{name: "unset returns default", set: false, def: "fallback", want: "fallback"},
		{name: "empty returns default", set: true, value: "", def: "fallback", want: "fallback"},
		{name: "set returns value", set: true, value: "override", def: "fallback", want: "override"},
		{name: "set value shadows empty default", set: true, value: "x", def: "", want: "x"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if tc.set {
				t.Setenv(key, tc.value)
			} else {
				// t.Setenv can't unset, but the probe key is unique + never set by the
				// suite, so Getenv returns "" here — the unset branch.
				os.Unsetenv(key)
			}
			if got := getenv(key, tc.def); got != tc.want {
				t.Errorf("getenv(%q, %q) = %q, want %q", key, tc.def, got, tc.want)
			}
		})
	}
}

// With $HELIX_PG_DSN unset/empty, run must fail closed with the specific
// "$HELIX_PG_DSN is required" message BEFORE opening Postgres or Redis. Regression
// guard: removing the guard makes run reach store.Open("") → a different
// ("open postgres") error, so this message assertion FAILs.
func TestRun_EmptyDSNIsRequired(t *testing.T) {
	t.Setenv("HELIX_PG_DSN", "")

	err := run(":0")
	if err == nil {
		t.Fatal("run(no dsn) = nil, want required-dsn error")
	}
	if !strings.Contains(err.Error(), "HELIX_PG_DSN") || !strings.Contains(err.Error(), "required") {
		t.Errorf("run(no dsn) err = %q, want the $HELIX_PG_DSN-required message", err)
	}
}

// A non-empty but MALFORMED $HELIX_PG_DSN passes the required-dsn guard, then
// fails in store.Open; run must wrap it as "open postgres: ...". The malformed DSN
// is a pure pgx parse error — no TCP connection is attempted, so the test is
// hermetic and fast (well under the 10s openCtx budget). Regression guard: if the
// store.Open error is swallowed / not wrapped, the "open postgres" prefix FAILs.
func TestRun_StoreOpenErrorWrapped(t *testing.T) {
	t.Setenv("HELIX_PG_DSN", "this is not a valid postgres dsn")

	start := time.Now()
	err := run(":0")
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("run(malformed dsn) = nil, want open-postgres error")
	}
	if !strings.HasPrefix(err.Error(), "open postgres:") {
		t.Errorf("run(malformed dsn) err = %q, want it to start with %q", err, "open postgres:")
	}
	// Proof of hermeticity: a parse failure returns immediately; a genuine socket
	// attempt would burn seconds against the 10s openCtx. Guard against a regression
	// that turns this into a real (slow, non-hermetic) connect.
	if elapsed > 5*time.Second {
		t.Errorf("run(malformed dsn) took %v, want a fast parse error (no socket attempt)", elapsed)
	}
}

// main() with -version prints "api <version>" to stdout and returns WITHOUT
// requiring any backend. Regression guard: removing the version short-circuit
// makes main() fall through to run() → the $HELIX_PG_DSN guard → os.Exit(1), which
// would abort the test process; the presence of the version line proves the
// short-circuit fired.
//
// main() registers its flags on the process-global flag.CommandLine; a fresh
// FlagSet is swapped in (and os.Args set) for the duration of the call and both
// restored afterwards, so the test is idempotent under -count=N (§11.4.50) — a
// second invocation would otherwise panic "flag redefined: version" — and leaves
// no global state behind for sibling tests.
func TestMain_VersionShortCircuits(t *testing.T) {
	origArgs := os.Args
	origFlags := flag.CommandLine
	defer func() { os.Args = origArgs; flag.CommandLine = origFlags }()
	os.Args = []string{"api", "-version"}
	flag.CommandLine = flag.NewFlagSet("api", flag.ContinueOnError)

	out := captureStdout(t, func() { main() })

	if !strings.Contains(out, "api "+version) {
		t.Errorf("main(-version) stdout = %q, want it to contain %q", out, "api "+version)
	}
}
