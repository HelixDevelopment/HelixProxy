// Hermetic unit tests for the REAL liveSampler.sample path and runProfile's
// error-logging fail-safe branches. The existing loop_test.go isolates the
// transition machinery behind a fake sampler + a never-failing publisher, so the
// concrete liveSampler (gluetun control client + wg reader) and the SetStatus /
// PublishEvent error paths were never exercised. These tests close that gap with
// an in-process httptest gluetun (no external network) and a fake `wg` binary
// (no privileged interface, no real WireGuard) — fully hermetic, run under -short.
package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// egressServer returns an httptest server answering the gluetun /v1/publicip/ip
// endpoint with the given body + status. It stands in for a REAL gluetun control
// API on an in-process 127.0.0.1 ephemeral port (no external network).
func egressServer(t *testing.T, status int, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// writeFakeWG writes an executable stub that mimics `wg show <if> <subcmd>`,
// emitting transferBody for `transfer` and hsBody for `latest-handshakes`
// (bodies carry \t / \n as two-char escapes, expanded by printf '%b'). It returns
// the stub path for use as WGReader.Bin — no real `wg` binary or interface needed.
func writeFakeWG(t *testing.T, transferBody, hsBody string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fake-wg")
	script := "#!/bin/sh\n" +
		"case \"$3\" in\n" +
		"  transfer) printf '%b' '" + transferBody + "' ;;\n" +
		"  latest-handshakes) printf '%b' '" + hsBody + "' ;;\n" +
		"esac\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake wg: %v", err)
	}
	return path
}

// TestLiveSampler_Sample_EgressAndWGSuccess drives BOTH data-plane reads to
// success: gluetun returns a real egress IP (whitespace-trimmed) AND the fake wg
// reports non-zero counters + a recent handshake. sample() must fold all of it
// into the snapshot with no error (the `if werr == nil` counters-set branch).
func TestLiveSampler_Sample_EgressAndWGSuccess(t *testing.T) {
	srv := egressServer(t, http.StatusOK, `{"public_ip":"  203.0.113.7  "}`)
	wgBin := writeFakeWG(t, `PUBKEY\t100\t250\n`, `PUBKEY\t1700000000\n`)

	s := liveSampler{
		ctrl:   vpn.NewControlClient(srv.URL),
		wg:     vpn.WGReader{Bin: wgBin},
		ifName: "hp-test-if0",
	}

	before := time.Now().UTC()
	snap, err := s.sample(context.Background(), "demo")
	if err != nil {
		t.Fatalf("sample: unexpected error: %v", err)
	}
	if snap.Profile != "demo" {
		t.Errorf("Profile = %q, want demo", snap.Profile)
	}
	if snap.EgressIP != "203.0.113.7" {
		t.Errorf("EgressIP = %q, want trimmed 203.0.113.7", snap.EgressIP)
	}
	if snap.Rx != 100 || snap.Tx != 250 {
		t.Errorf("rx/tx = %d/%d, want 100/250", snap.Rx, snap.Tx)
	}
	if snap.LastHandshake.Unix() != 1700000000 {
		t.Errorf("LastHandshake = %v (unix %d), want unix 1700000000", snap.LastHandshake, snap.LastHandshake.Unix())
	}
	if snap.CheckedAt.Before(before) {
		t.Errorf("CheckedAt %v must be at-or-after sample start %v", snap.CheckedAt, before)
	}
}

// TestLiveSampler_Sample_EgressOKWGError proves a wg failure (binary absent) is
// best-effort: it does NOT fail the sample. The egress reading survives, counters
// stay zero (so DecideHealth fails closed downstream), and no error is returned —
// the `else` (wg error → stderr) branch of sample().
func TestLiveSampler_Sample_EgressOKWGError(t *testing.T) {
	srv := egressServer(t, http.StatusOK, `{"public_ip":"198.51.100.22"}`)

	s := liveSampler{
		ctrl:   vpn.NewControlClient(srv.URL),
		wg:     vpn.WGReader{Bin: filepath.Join(t.TempDir(), "does-not-exist-wg")},
		ifName: "hp-test-if0",
	}

	snap, err := s.sample(context.Background(), "demo")
	if err != nil {
		t.Fatalf("wg failure must NOT fail the sample, got err: %v", err)
	}
	if snap.EgressIP != "198.51.100.22" {
		t.Errorf("EgressIP = %q, want 198.51.100.22 (survives wg failure)", snap.EgressIP)
	}
	if snap.Rx != 0 || snap.Tx != 0 {
		t.Errorf("rx/tx = %d/%d, want 0/0 when wg read fails", snap.Rx, snap.Tx)
	}
	if !snap.LastHandshake.IsZero() {
		t.Errorf("LastHandshake = %v, want zero when wg read fails", snap.LastHandshake)
	}
}

// TestLiveSampler_Sample_EgressErrorPropagates proves the ONE sample-level
// failure: an unreachable / erroring gluetun (HTTP 500). sample() must return the
// error (caller turns it into a fresh DOWN) and NOT fabricate an egress reading.
func TestLiveSampler_Sample_EgressErrorPropagates(t *testing.T) {
	srv := egressServer(t, http.StatusInternalServerError, `boom`)

	s := liveSampler{
		ctrl:   vpn.NewControlClient(srv.URL),
		wg:     vpn.WGReader{Bin: filepath.Join(t.TempDir(), "unused-wg")},
		ifName: "hp-test-if0",
	}

	snap, err := s.sample(context.Background(), "demo")
	if err == nil {
		t.Fatal("erroring gluetun must return a sample error, got nil")
	}
	if snap.EgressIP != "" {
		t.Errorf("EgressIP = %q, want empty on egress failure (no fabrication)", snap.EgressIP)
	}
}

// TestLiveSampler_Sample_MalformedEgressJSON proves a reachable gluetun returning
// non-JSON body still surfaces as a sample error (decode failure), not a silent
// empty-egress pass.
func TestLiveSampler_Sample_MalformedEgressJSON(t *testing.T) {
	srv := egressServer(t, http.StatusOK, `<<not-json>>`)

	s := liveSampler{
		ctrl:   vpn.NewControlClient(srv.URL),
		wg:     vpn.WGReader{Bin: filepath.Join(t.TempDir(), "unused-wg")},
		ifName: "hp-test-if0",
	}

	if _, err := s.sample(context.Background(), "demo"); err == nil {
		t.Fatal("malformed egress JSON must return a decode error, got nil")
	}
}

// failingPub returns an error from BOTH SetStatus and PublishEvent so runProfile's
// fail-safe error-logging branches (which the never-failing recordingPub in
// loop_test.go cannot reach) are exercised. It records call counts so the test can
// assert both error paths actually fired.
type failingPub struct {
	mu           sync.Mutex
	setCalls     int
	publishCalls int
}

func (p *failingPub) SetStatus(_ context.Context, _ vpn.HealthSnapshot, _ int) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.setCalls++
	return errors.New("redis SetStatus down")
}

func (p *failingPub) PublishEvent(_ context.Context, _ redis.Event) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.publishCalls++
	return errors.New("redis PublishEvent down")
}

func (p *failingPub) counts() (int, int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.setCalls, p.publishCalls
}

// TestRunProfile_PublisherErrorsAreLoggedNotFatal drives one unknown→up
// transition against a publisher that errors on every call. runProfile must keep
// looping (both errors only logged to stderr, never fatal) and must attempt BOTH
// SetStatus (every poll) and PublishEvent (on the transition).
func TestRunProfile_PublisherErrorsAreLoggedNotFatal(t *testing.T) {
	now := time.Now().UTC()
	up := vpn.HealthSnapshot{
		Tx: 4096, LastHandshake: now.Add(-5 * time.Second), CheckedAt: now, EgressIP: "203.0.113.9",
	}
	s := &scriptSampler{steps: []scriptStep{{snap: up}}}
	pub := &failingPub{}
	eval := vpn.DataPlaneEvaluator{Freshness: 180 * time.Second}
	c := config{interval: 20 * time.Millisecond, ttlSeconds: 5, hostIP: "198.51.100.7"}

	ctx, cancel := context.WithCancel(context.Background())
	go runProfile(ctx, c, "demo", s, eval, pub)
	time.Sleep(80 * time.Millisecond)
	cancel()
	time.Sleep(30 * time.Millisecond)

	setCalls, publishCalls := pub.counts()
	if setCalls < 1 {
		t.Errorf("SetStatus must be attempted every poll, got %d calls", setCalls)
	}
	if publishCalls < 1 {
		t.Errorf("PublishEvent must be attempted on the unknown→up transition, got %d calls", publishCalls)
	}
}
