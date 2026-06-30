package aclhelper

import (
	"context"
	"errors"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// fakeBus is an in-memory Bus for unit tests (mocks/stubs permitted ONLY in unit
// tests, §11.4.27). Each field lets a case program one branch of the decision.
type fakeBus struct {
	route    redis.Route
	routeErr error
	snap     vpn.HealthSnapshot
	snapErr  error
}

func (f fakeBus) GetRoute(_ context.Context, target string) (redis.Route, error) {
	if f.routeErr != nil {
		return redis.Route{}, f.routeErr
	}
	r := f.route
	if r.Target == "" {
		r.Target = target
	}
	return r, nil
}

func (f fakeBus) GetStatus(_ context.Context, profile string) (vpn.HealthSnapshot, error) {
	if f.snapErr != nil {
		// Mirror the real client: a DOWN-safe snapshot AND the error.
		return vpn.HealthSnapshot{Profile: profile, State: vpn.StateDown}, f.snapErr
	}
	s := f.snap
	if s.Profile == "" {
		s.Profile = profile
	}
	return s, nil
}

func up(tunnel string) vpn.HealthSnapshot {
	return vpn.HealthSnapshot{Profile: tunnel, State: vpn.StateUp, CheckedAt: time.Now().UTC()}
}

// TestDecide_FailClosed is the authoritative fail-closed table. OK (with tag) is
// returned ONLY on route+up; every other input is ERR. This is the gate the §1.1
// paired mutation must break (qa-results/p5-aclhelper/.../mutation_red.log).
func TestDecide_FailClosed(t *testing.T) {
	cases := []struct {
		name    string
		host    string
		bus     fakeBus
		wantOK  bool
		wantTag string
	}{
		{
			name:    "route present and tunnel up -> OK tag",
			host:    "target-a",
			bus:     fakeBus{route: redis.Route{Tunnel: "tun_a"}, snap: up("tun_a")},
			wantOK:  true,
			wantTag: "tun_a",
		},
		{
			name: "no route -> ERR",
			host: "target-a",
			bus:  fakeBus{routeErr: redis.ErrRouteNotFound},
		},
		{
			name: "route present but tunnel down -> ERR",
			host: "target-a",
			bus:  fakeBus{route: redis.Route{Tunnel: "tun_a"}, snap: vpn.HealthSnapshot{Profile: "tun_a", State: vpn.StateDown}},
		},
		{
			name: "route present but tunnel unknown -> ERR",
			host: "target-a",
			bus:  fakeBus{route: redis.Route{Tunnel: "tun_a"}, snap: vpn.HealthSnapshot{Profile: "tun_a", State: vpn.StateUnknown}},
		},
		{
			name: "GetRoute transport error -> ERR",
			host: "target-a",
			bus:  fakeBus{routeErr: errors.New("redis: get route: dial tcp: connection refused")},
		},
		{
			name: "GetStatus transport error -> ERR",
			host: "target-a",
			bus:  fakeBus{route: redis.Route{Tunnel: "tun_a"}, snapErr: errors.New("redis: get status: i/o timeout")},
		},
		{
			name: "route with empty tunnel -> ERR",
			host: "target-a",
			bus:  fakeBus{route: redis.Route{Tunnel: ""}, snap: up("")},
		},
		{
			name: "empty host -> ERR",
			host: "",
			bus:  fakeBus{route: redis.Route{Tunnel: "tun_a"}, snap: up("tun_a")},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := Decider{Bus: tc.bus}
			ok, tag := d.Decide(context.Background(), tc.host)
			if ok != tc.wantOK || tag != tc.wantTag {
				t.Fatalf("Decide(%q) = (ok=%v, tag=%q), want (ok=%v, tag=%q)",
					tc.host, ok, tag, tc.wantOK, tc.wantTag)
			}
		})
	}
}

// TestDecide_EndToEndReplyString proves the decision composes with the protocol
// codec into the exact wire bytes Squid expects.
func TestDecide_EndToEndReplyString(t *testing.T) {
	d := Decider{Bus: fakeBus{route: redis.Route{Tunnel: "tun_a"}, snap: up("tun_a")}}

	// Concurrency-framed request line -> echoed channel + OK tag.
	req := ParseLine("5 target-a\n")
	ok, tag := d.Decide(context.Background(), req.Host)
	if got, want := FormatReply(req.Channel, ok, tag), "5 OK tag=tun_a\n"; got != want {
		t.Fatalf("reply = %q, want %q", got, want)
	}

	// Down tunnel -> ERR (channel echoed).
	dDown := Decider{Bus: fakeBus{route: redis.Route{Tunnel: "tun_a"}, snap: vpn.HealthSnapshot{State: vpn.StateDown}}}
	req2 := ParseLine("5 target-a\n")
	ok2, tag2 := dDown.Decide(context.Background(), req2.Host)
	if got, want := FormatReply(req2.Channel, ok2, tag2), "5 ERR\n"; got != want {
		t.Fatalf("down reply = %q, want %q", got, want)
	}
}
