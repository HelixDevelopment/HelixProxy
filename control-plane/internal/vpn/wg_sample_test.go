// Unit tests for WGReader.bin() (default vs override) and WGReader.Sample() — the
// live-`wg` reader. Sample is exercised against a fake `wg` binary (a tiny shell
// script written to t.TempDir(), NEVER the operator's real wg0-mullvad interface
// §11.4.133) that branches on the `wg show <if> <sub>` sub-command, so the real
// exec + real parser path runs and the fail-closed (exec/parse error → DOWN, never
// fabricated counters §11.4.107) branches are asserted. Stdlib + /bin/sh only.
package vpn

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
	"time"
)

func TestWGReader_bin(t *testing.T) {
	t.Parallel()
	if got := (WGReader{}).bin(); got != "wg" {
		t.Errorf("default bin = %q, want wg", got)
	}
	if got := (WGReader{Bin: "/usr/bin/wg-custom"}).bin(); got != "/usr/bin/wg-custom" {
		t.Errorf("override bin = %q", got)
	}
}

// writeFakeWG writes an executable /bin/sh script acting as `wg`; it prints the
// given transfer/handshake bodies (or exits non-zero) based on the sub-command
// ($3 == transfer|latest-handshakes) and returns its path.
func writeFakeWG(t *testing.T, transferBody, hsBody string, transferExit, hsExit int) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake-wg shell script requires a POSIX shell") // SKIP-OK: Linux/macOS test env
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "wg")
	script := "#!/bin/sh\n" +
		"case \"$3\" in\n" +
		"  transfer)\n" +
		"    " + emitOrExit(transferBody, transferExit) + "\n" +
		"    ;;\n" +
		"  latest-handshakes)\n" +
		"    " + emitOrExit(hsBody, hsExit) + "\n" +
		"    ;;\n" +
		"  *) exit 99 ;;\n" +
		"esac\n"
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatalf("write fake wg: %v", err)
	}
	return path
}

func emitOrExit(body string, exit int) string {
	if exit != 0 {
		return "exit " + strconv.Itoa(exit)
	}
	// printf with the body already containing \t / \n escape sequences.
	return "printf '" + body + "'"
}

func TestWGReader_Sample_Success(t *testing.T) {
	t.Parallel()
	bin := writeFakeWG(t, `PUBKEY\t100\t250\n`, `PUBKEY\t1700000000\n`, 0, 0)
	r := WGReader{Bin: bin}
	rx, tx, latest, err := r.Sample(context.Background(), "wg-fake0")
	if err != nil {
		t.Fatalf("Sample: unexpected err %v", err)
	}
	if rx != 100 || tx != 250 {
		t.Errorf("rx/tx = %d/%d, want 100/250", rx, tx)
	}
	if want := time.Unix(1700000000, 0).UTC(); !latest.Equal(want) {
		t.Errorf("latest = %s, want %s", latest, want)
	}
}

func TestWGReader_Sample_TransferExecError(t *testing.T) {
	t.Parallel()
	// A binary that does not exist → the first exec fails → fail-closed error.
	r := WGReader{Bin: filepath.Join(t.TempDir(), "does-not-exist-wg")}
	if _, _, _, err := r.Sample(context.Background(), "wg-fake0"); err == nil {
		t.Fatal("missing wg binary must return an error (fail-closed), got nil")
	}
}

func TestWGReader_Sample_TransferParseError(t *testing.T) {
	t.Parallel()
	// Malformed transfer line (2 fields, not 3) → ParseTransfer error surfaces.
	bin := writeFakeWG(t, `PUBKEY\t100\n`, `PUBKEY\t1700000000\n`, 0, 0)
	r := WGReader{Bin: bin}
	if _, _, _, err := r.Sample(context.Background(), "wg-fake0"); err == nil {
		t.Fatal("malformed transfer must return a parse error, got nil")
	}
}

func TestWGReader_Sample_HandshakeExecError(t *testing.T) {
	t.Parallel()
	// transfer OK, latest-handshakes exits non-zero → second exec fail-closed.
	bin := writeFakeWG(t, `PUBKEY\t100\t250\n`, "", 0, 3)
	r := WGReader{Bin: bin}
	if _, _, _, err := r.Sample(context.Background(), "wg-fake0"); err == nil {
		t.Fatal("latest-handshakes exec failure must return an error, got nil")
	}
}

func TestWGReader_Sample_HandshakeParseError(t *testing.T) {
	t.Parallel()
	// transfer OK, handshake epoch not an integer → ParseLatestHandshakes error.
	bin := writeFakeWG(t, `PUBKEY\t100\t250\n`, `PUBKEY\tnot-an-epoch\n`, 0, 0)
	r := WGReader{Bin: bin}
	if _, _, _, err := r.Sample(context.Background(), "wg-fake0"); err == nil {
		t.Fatal("malformed handshake must return a parse error, got nil")
	}
}
