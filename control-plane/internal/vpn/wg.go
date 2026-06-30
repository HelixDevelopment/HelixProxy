// wg.go — parsers for `wg show <if> transfer` and `wg show <if> latest-handshakes`
// output (design spec §4 component 1: the `wg show <if> transfer` byte-delta).
// The parsers take a STRING so they are unit-testable from captured fixtures, not
// only from a live `wg` binary. A live reader (WGReader) shells out via os/exec
// and feeds the same parsers; when `wg` or the interface is unavailable it returns
// an error and the caller treats the tunnel as DOWN (fail-closed, §11.4.107).
// Stdlib only (os/exec, strconv, strings, time).
package vpn

import (
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// PeerTransfer is one peer's cumulative byte counters from `wg show <if> transfer`.
// Output format is tab-separated: "<public-key>\t<rx-bytes>\t<tx-bytes>".
type PeerTransfer struct {
	PublicKey string
	Rx        uint64
	Tx        uint64
}

// PeerHandshake is one peer's latest-handshake from `wg show <if> latest-handshakes`.
// Output format is "<public-key>\t<unix-epoch-seconds>"; epoch 0 means "never"
// and is represented as a zero time.Time.
type PeerHandshake struct {
	PublicKey string
	At        time.Time
}

// ParseTransfer parses `wg show <if> transfer` output. Blank lines are skipped.
// A malformed line is an error (a parse bug must surface, not silently zero —
// §11.4.1: a FAIL-bluff is as bad as a PASS-bluff).
func ParseTransfer(out string) ([]PeerTransfer, error) {
	var peers []PeerTransfer
	for i, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 3 {
			return nil, fmt.Errorf("wg transfer: line %d: want 3 tab-separated fields, got %d: %q", i+1, len(fields), line)
		}
		rx, err := strconv.ParseUint(strings.TrimSpace(fields[1]), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("wg transfer: line %d: rx %q: %w", i+1, fields[1], err)
		}
		tx, err := strconv.ParseUint(strings.TrimSpace(fields[2]), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("wg transfer: line %d: tx %q: %w", i+1, fields[2], err)
		}
		peers = append(peers, PeerTransfer{PublicKey: strings.TrimSpace(fields[0]), Rx: rx, Tx: tx})
	}
	return peers, nil
}

// SumTransfer totals rx/tx across all peers (a tunnel may have several peers).
func SumTransfer(peers []PeerTransfer) (rx, tx uint64) {
	for _, p := range peers {
		rx += p.Rx
		tx += p.Tx
	}
	return rx, tx
}

// ParseLatestHandshakes parses `wg show <if> latest-handshakes` output. An epoch
// of 0 ("never handshaked") becomes a zero time.Time.
func ParseLatestHandshakes(out string) ([]PeerHandshake, error) {
	var peers []PeerHandshake
	for i, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 2 {
			return nil, fmt.Errorf("wg latest-handshakes: line %d: want 2 tab-separated fields, got %d: %q", i+1, len(fields), line)
		}
		epoch, err := strconv.ParseInt(strings.TrimSpace(fields[1]), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("wg latest-handshakes: line %d: epoch %q: %w", i+1, fields[1], err)
		}
		var at time.Time
		if epoch > 0 {
			at = time.Unix(epoch, 0).UTC()
		}
		peers = append(peers, PeerHandshake{PublicKey: strings.TrimSpace(fields[0]), At: at})
	}
	return peers, nil
}

// LatestHandshake returns the most recent non-zero handshake across peers, or the
// zero time.Time when no peer has ever handshaked (⇒ stale ⇒ DOWN downstream).
func LatestHandshake(peers []PeerHandshake) time.Time {
	var latest time.Time
	for _, p := range peers {
		if p.At.After(latest) {
			latest = p.At
		}
	}
	return latest
}

// WGReader runs the real `wg` binary and parses its output. Bin defaults to "wg".
type WGReader struct {
	Bin string
}

func (r WGReader) bin() string {
	if r.Bin != "" {
		return r.Bin
	}
	return "wg"
}

// Sample reads cumulative rx/tx and the latest handshake for ifName by shelling
// out to `wg show <if> transfer` and `wg show <if> latest-handshakes`. Any exec
// failure (binary missing, interface absent, no privilege) is returned as an
// error so the caller fails closed (DOWN). It never fabricates counters.
func (r WGReader) Sample(ctx context.Context, ifName string) (rx, tx uint64, latest time.Time, err error) {
	transferOut, err := exec.CommandContext(ctx, r.bin(), "show", ifName, "transfer").Output()
	if err != nil {
		return 0, 0, time.Time{}, fmt.Errorf("wg show %s transfer: %w", ifName, err)
	}
	peers, err := ParseTransfer(string(transferOut))
	if err != nil {
		return 0, 0, time.Time{}, err
	}
	rx, tx = SumTransfer(peers)

	hsOut, err := exec.CommandContext(ctx, r.bin(), "show", ifName, "latest-handshakes").Output()
	if err != nil {
		return 0, 0, time.Time{}, fmt.Errorf("wg show %s latest-handshakes: %w", ifName, err)
	}
	hs, err := ParseLatestHandshakes(string(hsOut))
	if err != nil {
		return 0, 0, time.Time{}, err
	}
	return rx, tx, LatestHandshake(hs), nil
}
