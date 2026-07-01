// Unit tests for loadConfig's per-profile env-override + TTL branches and
// parseDuration's invalid-input fallback — the paths TestLoadConfig_Defaults
// (all-defaults) does not reach. Env is set via t.Setenv (auto-restored), so the
// precedence rules (profile-specific > global > default) are asserted as behaviour.
package main

import (
	"testing"
	"time"
)

func TestLoadConfig_EnvOverrides(t *testing.T) {
	// Profile-specific and global overrides plus explicit TTL / host-IP / max-age.
	t.Setenv("HEALTHD_PROFILES", "demo, euwg")
	t.Setenv("HEALTHD_GLUETUN_BASE_DEMO", "http://demo-host:9000")
	t.Setenv("HEALTHD_WG_IF_DEMO", "wgdemo")
	t.Setenv("HEALTHD_WG_IF", "wgglobal")
	t.Setenv("HEALTHD_TTL_SECONDS", "42")
	t.Setenv("HEALTHD_HOST_IP", "10.9.9.9")
	t.Setenv("HEALTHD_REDIS_MAXAGE", "90s")
	t.Setenv("HEALTHD_POLL_INTERVAL", "10s")
	t.Setenv("HEALTHD_FRESHNESS", "200s")

	c := loadConfig()

	if len(c.profiles) != 2 || c.profiles[0] != "demo" || c.profiles[1] != "euwg" {
		t.Fatalf("profiles = %v, want [demo euwg]", c.profiles)
	}
	// profile-specific gluetun base wins for demo; euwg falls back to default.
	if got := c.gluetunBase("demo"); got != "http://demo-host:9000" {
		t.Errorf("gluetunBase(demo) = %q, want override", got)
	}
	// profile-specific wg-if wins for demo; euwg falls back to the global HEALTHD_WG_IF.
	if got := c.wgIf("demo"); got != "wgdemo" {
		t.Errorf("wgIf(demo) = %q, want wgdemo", got)
	}
	if got := c.wgIf("euwg"); got != "wgglobal" {
		t.Errorf("wgIf(euwg) = %q, want global wgglobal", got)
	}
	if c.ttlSeconds != 42 {
		t.Errorf("ttlSeconds = %d, want explicit 42", c.ttlSeconds)
	}
	if c.hostIP != "10.9.9.9" {
		t.Errorf("hostIP = %q, want 10.9.9.9", c.hostIP)
	}
	if c.maxAge != 90*time.Second {
		t.Errorf("maxAge = %s, want 90s", c.maxAge)
	}
	if c.interval != 10*time.Second || c.freshness != 200*time.Second {
		t.Errorf("interval/freshness = %s/%s", c.interval, c.freshness)
	}
}

// TestLoadConfig_TTLClampFloor covers the computed-TTL floor: with no explicit
// HEALTHD_TTL_SECONDS and a sub-second interval, 3*interval rounds to 0 and MUST be
// clamped up to 1 (a 0-second TTL would never fail-close the Redis key).
func TestLoadConfig_TTLClampFloor(t *testing.T) {
	t.Setenv("HEALTHD_TTL_SECONDS", "")        // force the computed path
	t.Setenv("HEALTHD_POLL_INTERVAL", "100ms") // 3*0.1s = 0.3s → int 0 → clamp to 1
	c := loadConfig()
	if c.ttlSeconds != 1 {
		t.Errorf("ttlSeconds = %d, want clamped floor 1", c.ttlSeconds)
	}
}

// TestLoadConfig_InvalidTTLIgnored covers the strconv.Atoi error branch of the TTL
// selection: a non-numeric HEALTHD_TTL_SECONDS falls back to the computed value.
func TestLoadConfig_InvalidTTLIgnored(t *testing.T) {
	t.Setenv("HEALTHD_TTL_SECONDS", "not-a-number")
	t.Setenv("HEALTHD_POLL_INTERVAL", "5s")
	c := loadConfig()
	if c.ttlSeconds != 15 { // 3 * 5s, computed fallback
		t.Errorf("ttlSeconds = %d, want computed 15 (invalid explicit ignored)", c.ttlSeconds)
	}
}

func TestParseDuration(t *testing.T) {
	def := 7 * time.Second
	cases := []struct {
		name, in string
		want     time.Duration
	}{
		{"valid", "3s", 3 * time.Second},
		{"empty falls back", "", def},
		{"garbage falls back", "not-a-duration", def},
		{"zero falls back", "0s", def},
		{"negative falls back", "-2s", def},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := parseDuration(tc.in, def); got != tc.want {
				t.Errorf("parseDuration(%q) = %s, want %s", tc.in, got, tc.want)
			}
		})
	}
}
