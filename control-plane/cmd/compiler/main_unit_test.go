// Unit tests (no live database, no containers, no network) for the compiler
// BINARY's argument-handling + fail-closed branches and the writeFile helper.
// The integration test (main_integration_test.go) proves the full DB→artifact→
// Redis path against real services; these tests deterministically exercise the
// branches that DO NOT need a data plane — version/flag-parse/empty-DSN guards,
// the store.Open error wrap (via a MALFORMED DSN → a pure parse error, no socket
// is ever opened), and writeFile's mkdir/write success + failure paths. Each
// assertion pins genuine behaviour: flipping any guarded branch to success, or
// dropping an error wrap, makes a test FAIL (§11.4.1 no FAIL-bluff, §11.4.115).
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// captureStdout runs fn with os.Stdout redirected to a pipe and returns what fn
// printed. Used to assert run()'s user-facing output on the version short-circuit.
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

// --version short-circuits: prints "compiler <version>" and returns nil BEFORE
// any DSN requirement. Regression guard: if the version branch is removed, run
// falls through to the --dsn guard and returns an error (test FAILs).
func TestRun_VersionShortCircuits(t *testing.T) {
	// Ensure the env-sourced flag defaults cannot supply a DSN behind our back.
	t.Setenv("HELIX_PG_DSN", "")
	t.Setenv("HELIX_REDIS_ADDR", "")

	var err error
	out := captureStdout(t, func() { err = run([]string{"--version"}) })
	if err != nil {
		t.Fatalf("run(--version) = %v, want nil", err)
	}
	if !strings.Contains(out, "compiler "+version) {
		t.Errorf("run(--version) stdout = %q, want it to contain %q", out, "compiler "+version)
	}
}

// An unknown flag makes flag.FlagSet.Parse (ContinueOnError) return an error,
// which run must propagate. Regression guard: dropping the `if err := fs.Parse`
// check would let the bad invocation proceed.
func TestRun_FlagParseError(t *testing.T) {
	t.Setenv("HELIX_PG_DSN", "")
	t.Setenv("HELIX_REDIS_ADDR", "")

	// Silence the FlagSet's usage dump (defaults to os.Stderr) to keep test output
	// clean; the returned error is what we assert on.
	origErr := os.Stderr
	if devnull, oerr := os.Open(os.DevNull); oerr == nil {
		os.Stderr = devnull
		defer func() { os.Stderr = origErr; _ = devnull.Close() }()
	}

	if err := run([]string{"--this-flag-does-not-exist"}); err == nil {
		t.Fatal("run(unknown-flag) = nil, want a parse error")
	}
}

// With neither --dsn nor $HELIX_PG_DSN set, run must fail closed with the
// specific "--dsn ... is required" message BEFORE opening anything. Regression
// guard: removing the guard makes run reach store.Open("") → a different
// ("open store") error, so the message assertion FAILs.
func TestRun_EmptyDSNIsRequired(t *testing.T) {
	t.Setenv("HELIX_PG_DSN", "")
	t.Setenv("HELIX_REDIS_ADDR", "")

	err := run([]string{"--squid-out", filepath.Join(t.TempDir(), "x.conf")})
	if err == nil {
		t.Fatal("run(no dsn) = nil, want required-dsn error")
	}
	if !strings.Contains(err.Error(), "--dsn") || !strings.Contains(err.Error(), "required") {
		t.Errorf("run(no dsn) err = %q, want the --dsn-required message", err)
	}
}

// A non-empty but MALFORMED --dsn passes the required-dsn guard, then fails in
// store.Open; run must wrap it as "open store: ...". The malformed DSN is a pure
// pgx parse error — no TCP connection is attempted, so the test is hermetic and
// fast. Regression guard: if the store.Open error is swallowed / not wrapped, the
// "open store" prefix assertion FAILs.
func TestRun_StoreOpenErrorWrapped(t *testing.T) {
	t.Setenv("HELIX_PG_DSN", "")
	t.Setenv("HELIX_REDIS_ADDR", "")

	err := run([]string{"--dsn", "this is not a valid postgres dsn"})
	if err == nil {
		t.Fatal("run(malformed dsn) = nil, want open-store error")
	}
	if !strings.HasPrefix(err.Error(), "open store:") {
		t.Errorf("run(malformed dsn) err = %q, want it to start with %q", err, "open store:")
	}
}

// The --dsn value defaults from $HELIX_PG_DSN when the flag is absent; a
// malformed env DSN must still reach the (wrapped) store.Open error, proving the
// env-sourced default path is live. Regression guard: if the flag stopped
// defaulting from the env var, run would hit the empty-dsn guard instead and the
// "open store" prefix assertion would FAIL.
func TestRun_DSNFromEnv(t *testing.T) {
	t.Setenv("HELIX_PG_DSN", "still not a valid dsn")
	t.Setenv("HELIX_REDIS_ADDR", "")

	err := run(nil)
	if err == nil {
		t.Fatal("run(env dsn) = nil, want open-store error")
	}
	if !strings.HasPrefix(err.Error(), "open store:") {
		t.Errorf("run(env dsn) err = %q, want it to start with %q (env default not applied?)", err, "open store:")
	}
}

// writeFile creates missing parent dirs and writes the bytes verbatim. Regression
// guard: dropping the MkdirAll leaves the nested write failing; a content
// mismatch catches a corrupted write.
func TestWriteFile_CreatesParentsAndWrites(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "a", "b", "c", "out.conf")
	want := []byte("http_port 3128\ninclude x\n")

	if err := writeFile(path, want); err != nil {
		t.Fatalf("writeFile: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if string(got) != string(want) {
		t.Errorf("content = %q, want %q", got, want)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	// Not executable, owner-writable (catches a regression to 0755 or 0400 without
	// being brittle to the host umask).
	if perm := info.Mode().Perm(); perm&0o111 != 0 || perm&0o200 == 0 {
		t.Errorf("file perm = %o, want non-executable + owner-writable (rendered config, not a program)", perm)
	}
}

// writeFile with an empty dir component (relative bare filename) skips MkdirAll
// (dir == "." branch) and still writes. Regression guard: the `dir != "."` guard
// must hold — otherwise MkdirAll(".") churns needlessly; here we prove the write
// still lands.
func TestWriteFile_BareFilenameNoMkdir(t *testing.T) {
	root := t.TempDir()
	// chdir into tmp so a bare filename resolves there; restore afterwards.
	orig, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if cerr := os.Chdir(root); cerr != nil {
		t.Fatalf("chdir: %v", cerr)
	}
	defer func() { _ = os.Chdir(orig) }()

	if werr := writeFile("bare.conf", []byte("x")); werr != nil {
		t.Fatalf("writeFile bare: %v", werr)
	}
	if got, rerr := os.ReadFile(filepath.Join(root, "bare.conf")); rerr != nil || string(got) != "x" {
		t.Fatalf("bare write: got=%q err=%v", got, rerr)
	}
}

// When the parent path is an existing FILE, MkdirAll fails and writeFile must
// return a wrapped "mkdir ..." error (fail closed, no silent overwrite).
func TestWriteFile_MkdirErrorWhenParentIsFile(t *testing.T) {
	root := t.TempDir()
	blocker := filepath.Join(root, "iam-a-file")
	if err := os.WriteFile(blocker, []byte("occupied"), 0o644); err != nil {
		t.Fatalf("setup blocker: %v", err)
	}
	// filepath.Dir(path) == blocker, which is a file → MkdirAll fails.
	err := writeFile(filepath.Join(blocker, "child.conf"), []byte("nope"))
	if err == nil {
		t.Fatal("writeFile under a file-parent = nil, want mkdir error")
	}
	if !strings.HasPrefix(err.Error(), "mkdir ") {
		t.Errorf("err = %q, want it to start with %q", err, "mkdir ")
	}
}

// When the target path is an existing directory, MkdirAll(parent) succeeds but
// os.WriteFile fails; writeFile must return a wrapped "write ..." error.
func TestWriteFile_WriteErrorWhenPathIsDir(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "adir")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("setup dir: %v", err)
	}
	err := writeFile(dir, []byte("cannot write over a directory"))
	if err == nil {
		t.Fatal("writeFile onto a directory = nil, want write error")
	}
	if !strings.HasPrefix(err.Error(), "write ") {
		t.Errorf("err = %q, want it to start with %q", err, "write ")
	}
}
