// Unit tests for the healthd poll-loop transition logic (pollOnce + runProfile).
// These use a fake sampler + a recording publisher to prove: (1) a sampling error
// yields a fresh DOWN snapshot (fail-closed), (2) the loop writes every poll but
// publishes vpn:events ONLY on a state transition, (3) the tx-delta baseline
// advances between polls. The REAL bus (pub/sub) is exercised in the integration
// + chaos tests; here we isolate the transition machinery. Run under -short.
package main

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// scriptSampler returns successive snapshots from a script; an entry with err set
// simulates a sampling failure (e.g. gluetun unreachable).
type scriptStep struct {
	snap vpn.HealthSnapshot
	err  error
}

type scriptSampler struct {
	mu    sync.Mutex
	steps []scriptStep
	i     int
}

func (s *scriptSampler) sample(ctx context.Context, profile string) (vpn.HealthSnapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.i >= len(s.steps) {
		// Hold on the last step after the script is exhausted.
		last := s.steps[len(s.steps)-1]
		last.snap.Profile = profile
		return last.snap, last.err
	}
	st := s.steps[s.i]
	s.i++
	st.snap.Profile = profile
	return st.snap, st.err
}

type recordingPub struct {
	mu       sync.Mutex
	statuses []vpn.HealthSnapshot
	events   []redis.Event
}

func (p *recordingPub) SetStatus(_ context.Context, snap vpn.HealthSnapshot, _ int) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.statuses = append(p.statuses, snap)
	return nil
}
func (p *recordingPub) PublishEvent(_ context.Context, e redis.Event) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.events = append(p.events, e)
	return nil
}
func (p *recordingPub) snapshot() ([]vpn.HealthSnapshot, []redis.Event) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]vpn.HealthSnapshot(nil), p.statuses...), append([]redis.Event(nil), p.events...)
}

func TestPollOnce_SamplingErrorIsFailClosedDown(t *testing.T) {
	s := &scriptSampler{steps: []scriptStep{{err: errors.New("gluetun unreachable")}}}
	eval := vpn.DataPlaneEvaluator{Freshness: 180 * time.Second}
	got := pollOnce(context.Background(), "demo", s, eval, vpn.HealthSnapshot{}, "")
	if got.State != vpn.StateDown {
		t.Errorf("sampling error must be DOWN, got %q", got.State)
	}
	if got.CheckedAt.IsZero() {
		t.Error("DOWN snapshot must carry a fresh CheckedAt (TTL freshness)")
	}
}

// TestRunProfile_TransitionPublishesOnce drives a fake sampler UP→DOWN and proves
// the loop publishes exactly two events (unknown→up, up→down) — one per real
// transition — while writing a status on every poll.
func TestRunProfile_TransitionPublishesOnce(t *testing.T) {
	now := time.Now().UTC()
	up := vpn.HealthSnapshot{
		Tx: 4096, LastHandshake: now.Add(-10 * time.Second), CheckedAt: now, EgressIP: "203.0.113.9",
	}
	up2 := up
	up2.Tx = 8192 // still advancing → stays UP
	up2.CheckedAt = now.Add(50 * time.Millisecond)
	up2.LastHandshake = now
	s := &scriptSampler{steps: []scriptStep{
		{snap: up},                          // unknown → up
		{snap: up2},                         // up → up (no event)
		{err: errors.New("tunnel dropped")}, // up → down (event)
	}}
	pub := &recordingPub{}
	eval := vpn.DataPlaneEvaluator{Freshness: 180 * time.Second}
	c := config{interval: 20 * time.Millisecond, ttlSeconds: 5, hostIP: "198.51.100.7"}

	ctx, cancel := context.WithCancel(context.Background())
	go runProfile(ctx, c, "demo", s, eval, pub)
	// Let it run a handful of ticks, then stop.
	time.Sleep(150 * time.Millisecond)
	cancel()
	time.Sleep(30 * time.Millisecond)

	statuses, events := pub.snapshot()
	if len(statuses) < 3 {
		t.Fatalf("want >=3 status writes, got %d", len(statuses))
	}
	// Exactly the two transitions: up, then down.
	if len(events) != 2 {
		t.Fatalf("want exactly 2 transition events, got %d: %+v", len(events), events)
	}
	if events[0].State != vpn.StateUp || events[1].State != vpn.StateDown {
		t.Errorf("transition order wrong: %+v", events)
	}
	if events[0].ProfileID != "demo" {
		t.Errorf("event profile = %q, want demo", events[0].ProfileID)
	}
}

func TestLoadConfig_Defaults(t *testing.T) {
	// Clear env so we exercise the defaults deterministically.
	for _, k := range []string{
		"REDIS_ADDR", "HEALTHD_PROFILES", "GLUETUN_CONTROL_PORT", "HEALTHD_GLUETUN_BASE",
		"HEALTHD_POLL_INTERVAL", "HEALTHD_FRESHNESS", "HEALTHD_TTL_SECONDS", "HEALTHD_HOST_IP",
	} {
		t.Setenv(k, "")
	}
	c := loadConfig()
	if c.redisAddr != "127.0.0.1:6379" {
		t.Errorf("redisAddr default = %q", c.redisAddr)
	}
	if len(c.profiles) != 1 || c.profiles[0] != "demo" {
		t.Errorf("profiles default = %v", c.profiles)
	}
	if c.gluetunBase("demo") != "http://127.0.0.1:8000" {
		t.Errorf("gluetunBase default = %q", c.gluetunBase("demo"))
	}
	if c.wgIf("nordvpn-uk") != "nordvpn-uk" {
		t.Errorf("wgIf default should be profile name, got %q", c.wgIf("nordvpn-uk"))
	}
	if c.interval != 5*time.Second || c.freshness != 180*time.Second {
		t.Errorf("interval/freshness defaults = %s/%s", c.interval, c.freshness)
	}
	if c.ttlSeconds != 15 { // 3 * 5s
		t.Errorf("ttlSeconds default = %d, want 15", c.ttlSeconds)
	}
}

func TestEnvKey(t *testing.T) {
	if got := envKey("nordvpn-uk"); got != "NORDVPN_UK" {
		t.Errorf("envKey = %q, want NORDVPN_UK", got)
	}
}
