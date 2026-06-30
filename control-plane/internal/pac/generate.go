// Concrete pac.Generator implementation (design spec §11 ⑤, §4 component 4). It
// renders a deterministic `FindProxyForURL` body from the resolved entry set: each
// entry maps a host glob to a PAC return value, everything else is DIRECT
// (split-tunnel). Output is byte-stable — entries are sorted by host glob — so the
// PAC endpoint serves the same bytes for the same data model (§11.4.6 no-guessing,
// §11.4.50 deterministic consistency).
package pac

import (
	"bytes"
	"context"
	"fmt"
	"sort"
	"text/template"
)

// DefaultProxy is the PAC return value used when an Entry leaves Proxy empty.
// Mirrors routing.DefaultPACProxy so the API endpoint and the compiler agree.
const DefaultProxy = "PROXY proxy-squid:53128"

// FindProxyGenerator renders the FindProxyForURL artifact. The zero value is
// ready to use; New is provided for symmetry with the other packages.
type FindProxyGenerator struct{}

// compile-time assertion that *FindProxyGenerator satisfies the contract.
var _ Generator = (*FindProxyGenerator)(nil)

// NewGenerator builds a FindProxyGenerator.
func NewGenerator() *FindProxyGenerator { return &FindProxyGenerator{} }

var pacTmpl = template.Must(template.New("pac").Parse(
	`// Helix Proxy — proxy auto-config (GENERATED — DO NOT EDIT BY HAND).
// VPN-routed target aliases go through the proxy; everything else is DIRECT
// (split-tunnel, spec §11 ⑤). Served by the control-API /proxy.pac endpoint.
function FindProxyForURL(url, host) {
{{- range .}}
    if (shExpMatch(host, {{printf "%q" .HostGlob}})) { return {{printf "%q" .Proxy}}; }
{{- end}}
    return "DIRECT";
}
`))

// Generate renders the PAC body from entries. Entries are copied and sorted by
// HostGlob for deterministic output; an empty Proxy is normalised to DefaultProxy;
// entries with an empty HostGlob are skipped (they would match nothing usefully).
func (g *FindProxyGenerator) Generate(ctx context.Context, entries []Entry) ([]byte, error) {
	_ = ctx
	sorted := make([]Entry, 0, len(entries))
	for _, e := range entries {
		if e.HostGlob == "" {
			continue
		}
		if e.Proxy == "" {
			e.Proxy = DefaultProxy
		}
		sorted = append(sorted, e)
	}
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].HostGlob < sorted[j].HostGlob })
	var buf bytes.Buffer
	if err := pacTmpl.Execute(&buf, sorted); err != nil {
		return nil, fmt.Errorf("pac: render: %w", err)
	}
	return buf.Bytes(), nil
}
