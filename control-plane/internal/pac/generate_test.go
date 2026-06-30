package pac

import (
	"context"
	"strings"
	"testing"
)

func TestGenerate_FindProxyForURL_DeterministicAndSorted(t *testing.T) {
	g := NewGenerator()
	// Intentionally unsorted + one empty-proxy entry (normalised to DefaultProxy).
	entries := []Entry{
		{HostGlob: "metrics.helix", Proxy: "PROXY proxy-squid:53128"},
		{HostGlob: "db-bastion.helix", Proxy: ""},
		{HostGlob: "internal-wiki.helix", Proxy: "PROXY proxy-squid:53128"},
	}
	b1, err := g.Generate(context.Background(), entries)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	body := string(b1)

	if !strings.Contains(body, "function FindProxyForURL(url, host)") {
		t.Fatalf("missing FindProxyForURL:\n%s", body)
	}
	if !strings.Contains(body, `return "DIRECT";`) {
		t.Fatalf("missing DIRECT default:\n%s", body)
	}
	// Empty proxy normalised to the default.
	if !strings.Contains(body, `shExpMatch(host, "db-bastion.helix")) { return "PROXY proxy-squid:53128"; }`) {
		t.Fatalf("empty proxy not normalised to default:\n%s", body)
	}
	// Sorted: db-bastion < internal-wiki < metrics.
	iDB := strings.Index(body, "db-bastion.helix")
	iWiki := strings.Index(body, "internal-wiki.helix")
	iMetrics := strings.Index(body, "metrics.helix")
	if !(iDB < iWiki && iWiki < iMetrics) {
		t.Fatalf("aliases not sorted (db=%d wiki=%d metrics=%d):\n%s", iDB, iWiki, iMetrics, body)
	}

	// Deterministic: same input (shuffled) → byte-identical output.
	shuffled := []Entry{entries[2], entries[0], entries[1]}
	b2, _ := g.Generate(context.Background(), shuffled)
	if string(b2) != body {
		t.Fatalf("non-deterministic output:\n--- a ---\n%s\n--- b ---\n%s", body, b2)
	}
}

func TestGenerate_EmptyAndSkipsBlankGlob(t *testing.T) {
	g := NewGenerator()
	// No entries → just the DIRECT default.
	b, err := g.Generate(context.Background(), nil)
	if err != nil {
		t.Fatalf("generate empty: %v", err)
	}
	if !strings.Contains(string(b), `return "DIRECT";`) {
		t.Fatalf("empty PAC missing DIRECT:\n%s", b)
	}
	// A blank host glob is skipped (would match nothing usefully).
	b, _ = g.Generate(context.Background(), []Entry{{HostGlob: "", Proxy: "PROXY x:1"}})
	if strings.Contains(string(b), "shExpMatch") {
		t.Fatalf("blank glob should be skipped:\n%s", b)
	}
}
