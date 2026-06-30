// Unit tests for the wg output parsers, driven by captured fixtures (the exact
// tab-separated formats `wg show <if> transfer` and `wg show <if> latest-handshakes`
// emit). Covers byte sums, handshake-age, the "never handshaked" (epoch 0) case,
// and malformed-line errors (a parse bug must FAIL, not silently zero — §11.4.1).
package vpn

import (
	"testing"
	"time"
)

func TestParseTransfer(t *testing.T) {
	// Two peers; tab-separated "<pubkey>\t<rx>\t<tx>".
	fixture := "aGVsbG9wdWJrZXkxMjM0NTY3ODkwYWJjZGVmZ2hpamtsbW4=\t10485760\t20971520\n" +
		"c2Vjb25kcGVlcnB1YmtleTAwMDAwMDAwMDAwMDAwMDAwMDA=\t512\t1024\n"
	peers, err := ParseTransfer(fixture)
	if err != nil {
		t.Fatalf("ParseTransfer: %v", err)
	}
	if len(peers) != 2 {
		t.Fatalf("want 2 peers, got %d", len(peers))
	}
	if peers[0].Rx != 10485760 || peers[0].Tx != 20971520 {
		t.Errorf("peer0 rx/tx = %d/%d", peers[0].Rx, peers[0].Tx)
	}
	rx, tx := SumTransfer(peers)
	if rx != 10485760+512 || tx != 20971520+1024 {
		t.Errorf("sum rx/tx = %d/%d", rx, tx)
	}
}

func TestParseTransfer_Malformed(t *testing.T) {
	for _, bad := range []string{
		"onlytwo\t123\n",         // 2 fields
		"key\tnotanumber\t456\n", // bad rx
		"key\t123\tnotanumber\n", // bad tx
	} {
		if _, err := ParseTransfer(bad); err == nil {
			t.Errorf("ParseTransfer(%q) want error, got nil", bad)
		}
	}
}

func TestParseLatestHandshakes(t *testing.T) {
	now := time.Now().UTC()
	recent := now.Add(-45 * time.Second).Unix()
	older := now.Add(-3 * time.Minute).Unix()
	fixture := "peerA\t0\n" + // never handshaked → zero time
		"peerB\t" + itoa(older) + "\n" +
		"peerC\t" + itoa(recent) + "\n"
	hs, err := ParseLatestHandshakes(fixture)
	if err != nil {
		t.Fatalf("ParseLatestHandshakes: %v", err)
	}
	if len(hs) != 3 {
		t.Fatalf("want 3 peers, got %d", len(hs))
	}
	if !hs[0].At.IsZero() {
		t.Errorf("epoch 0 must be zero time, got %v", hs[0].At)
	}
	latest := LatestHandshake(hs)
	if latest.Unix() != recent {
		t.Errorf("LatestHandshake = %d, want %d", latest.Unix(), recent)
	}
	// Handshake age within a freshness window is what DecideHealth consumes.
	age := now.Sub(latest)
	if age < 0 || age > 90*time.Second {
		t.Errorf("expected recent handshake age ~45s, got %v", age)
	}
}

func TestLatestHandshake_AllNever(t *testing.T) {
	hs, err := ParseLatestHandshakes("peerA\t0\npeerB\t0\n")
	if err != nil {
		t.Fatalf("ParseLatestHandshakes: %v", err)
	}
	if !LatestHandshake(hs).IsZero() {
		t.Error("all-never must yield zero time (⇒ DOWN downstream)")
	}
}

func TestParseLatestHandshakes_Malformed(t *testing.T) {
	if _, err := ParseLatestHandshakes("peerA\tnotanumber\n"); err == nil {
		t.Error("bad epoch must be an error")
	}
	if _, err := ParseLatestHandshakes("peerA\t1\t2\n"); err == nil {
		t.Error("3 fields must be an error")
	}
}

// itoa avoids importing strconv just for the fixture builders.
func itoa(v int64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	if v == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for v > 0 {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
