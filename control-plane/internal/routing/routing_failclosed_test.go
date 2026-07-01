// §11.4.135 standing regression guard for the P10 fail-OPEN security defect:
// the VPN-aware dynamic proxy MUST fail CLOSED — with the tunnel down (or the
// compiler-rendered include absent) a client request MUST be denied (branded
// 503), NEVER egress directly. This test asserts the ASSEMBLED dynamic Squid
// config (the baked fail-closed base config/squid/squid.dynamic.conf, with the
// compiler-rendered include spliced in at its `include` line exactly as Squid
// expands it) is fail-closed-ORDERED:
//
//	(1) `http_access deny !tun_up` is present and reached BEFORE any client-allow
//	    (`http_access allow localnet`) — first-match-wins, so a leaked pre-include
//	    `allow localnet` would defeat the deny;
//	(2) `never_direct allow all` is present (no direct-egress path);
//	(3) the base carries NO unconditional pre-include `allow localnet`;
//	(4) a terminal `http_access deny all` backstops a MISSING include.
//
// §11.4.115 polarity switch: RED_MODE=1 reconstructs the PRE-FIX fail-OPEN
// assembly (unconditional `allow localnet` in the base BEFORE `deny all`, include
// appended at the END — exactly the shipped defect) and asserts the guard
// classifies it NOT-fail-closed (the RED reproduction). Default RED_MODE=0 is the
// standing GREEN guard over the real committed squid.dynamic.conf.
package routing

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// dynamicBaseRelPath is the committed fail-closed base config (repo-root-relative
// from this package dir). §11.4.3 SKIP-with-reason if absent (module isolation).
const dynamicBaseRelPath = "../../../config/squid/squid.dynamic.conf"

// includeMarker is the exact directive squid.dynamic.conf uses to pull the
// compiler-rendered include; assembleSquid splices the rendered bytes here,
// mirroring Squid's textual `include` expansion. It is the POSITIVE allow-list
// glob `*.squid` (NOT `*.conf`) so the base image's debian.conf `allow localnet`
// and the Dante `*.sockd.conf` are never pulled in (§11.4.108 RC-4).
const includeMarker = "include /etc/squid/conf.d/*.squid"

// assembleSquid returns the parse-order text Squid sees: base with the include
// directive replaced in-place by the rendered include bytes.
func assembleSquid(base string, include []byte) string {
	return strings.Replace(base, includeMarker, string(include), 1)
}

// directivesOnly drops `#` comment lines (and blank lines), mirroring Squid's
// own parse semantics — a rule mentioned in prose (e.g. "NO unconditional
// `http_access allow localnet`") is NOT a directive and MUST NOT match the
// ordering checks. Only real directive lines remain, order preserved.
func directivesOnly(s string) string {
	var b strings.Builder
	for _, ln := range strings.Split(s, "\n") {
		t := strings.TrimSpace(ln)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		b.WriteString(t)
		b.WriteByte('\n')
	}
	return b.String()
}

// failClosedOrdered reports whether an assembled config is fail-closed-ordered
// per the four invariants above. reason explains the first failing invariant.
// It operates on DIRECTIVE lines only (comments cannot satisfy or defeat a rule).
func failClosedOrdered(raw string) (ok bool, reason string) {
	assembled := directivesOnly(raw)
	denyTunUp := strings.Index(assembled, "http_access deny !tun_up")
	if denyTunUp < 0 {
		return false, "missing `http_access deny !tun_up` (no fail-closed gate)"
	}
	if !strings.Contains(assembled, "never_direct allow all") {
		return false, "missing `never_direct allow all` (a direct-egress path can leak)"
	}
	if !strings.Contains(assembled, "http_access deny all") {
		return false, "missing terminal `http_access deny all` (a missing include would not fail closed)"
	}
	// Every client-allow MUST come AFTER the deny gate (first-match-wins).
	for idx, rest := 0, assembled; ; {
		p := strings.Index(rest, "http_access allow localnet")
		if p < 0 {
			break
		}
		abs := idx + p
		if abs < denyTunUp {
			return false, "`http_access allow localnet` at offset " + itoa(abs) +
				" precedes `http_access deny !tun_up` at offset " + itoa(denyTunUp) +
				" — a LAN client egresses BEFORE the VPN check (fail-OPEN)"
		}
		idx = abs + len("http_access allow localnet")
		rest = assembled[idx:]
	}
	return true, ""
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

// TestFailClosed_AssembledDynamicConfig is the standing §11.4.135 guard.
func TestFailClosed_AssembledDynamicConfig(t *testing.T) {
	red := os.Getenv("RED_MODE") == "1"

	include := RenderSquidInclude("/usr/lib/helix-proxy/acl-helper",
		ResolveTunnels(fixtureProfiles()))

	// The rendered include itself must carry the gated allow AFTER the deny
	// (directive lines only — the template's prose comments do not count).
	incDir := directivesOnly(string(include))
	if di := strings.Index(incDir, "http_access deny !tun_up"); di >= 0 {
		if ai := strings.Index(incDir, "http_access allow localnet"); ai >= 0 && ai < di {
			t.Fatalf("rendered include emits `allow localnet` BEFORE `deny !tun_up` (fail-OPEN template)")
		}
	} else {
		t.Fatalf("rendered include missing `http_access deny !tun_up`")
	}

	if red {
		// §11.4.115 RED: reconstruct the PRE-FIX fail-OPEN assembly and assert the
		// guard catches it (unconditional allow localnet BEFORE deny all; include
		// appended at the END — the exact shipped defect).
		preFixBase := "http_port 0.0.0.0:53128\n" +
			"acl localnet src 10.0.0.0/8\n" +
			"http_access allow localnet\n" + // <-- unconditional, pre-include (the leak)
			"http_access allow localhost\n" +
			"http_access deny all\n" +
			includeMarker + "\n" // <-- appended AFTER deny all (unreachable rules)
		assembled := assembleSquid(preFixBase, include)
		ok, reason := failClosedOrdered(assembled)
		if ok {
			t.Fatalf("RED_MODE=1: guard FAILED to catch the known fail-OPEN assembly (bluff guard)")
		}
		t.Logf("RED_MODE=1 reproduced the P10 fail-OPEN defect; guard correctly rejects it: %s", reason)
		return
	}

	// GREEN: the REAL committed fail-closed base spliced with the real include.
	base, err := os.ReadFile(dynamicBaseRelPath)
	if err != nil {
		t.Skipf("SKIP (§11.4.3): %s unavailable in this checkout (%v)",
			filepath.Clean(dynamicBaseRelPath), err)
	}
	if !strings.Contains(string(base), includeMarker) {
		t.Fatalf("base %s missing include marker %q", dynamicBaseRelPath, includeMarker)
	}
	// The base MUST NOT carry an unconditional pre-include `allow localnet`
	// (directive lines only — the base's explanatory comments mention the phrase).
	beforeInclude := directivesOnly(string(base)[:strings.Index(string(base), includeMarker)])
	if strings.Contains(beforeInclude, "http_access allow localnet") {
		t.Fatalf("base %s has an unconditional `http_access allow localnet` BEFORE the include — fail-OPEN", dynamicBaseRelPath)
	}
	assembled := assembleSquid(string(base), include)
	if ok, reason := failClosedOrdered(assembled); !ok {
		t.Fatalf("assembled dynamic squid config is NOT fail-closed: %s", reason)
	}
	t.Logf("assembled dynamic squid config is fail-closed-ordered (deny !tun_up before any allow localnet; never_direct present; terminal deny all)")
}
