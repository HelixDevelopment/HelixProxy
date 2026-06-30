// Command api is the control-plane REST API + admin UI server (design spec §4
// component 4, §11 ⑥, plan Phase 6): CRUD over profiles/targets/rules/users,
// live status via SSE, a Prometheus /metrics endpoint, the FindProxyForURL PAC
// endpoint, and mTLS. It replaces the traefik/whoami placeholder.
//
// SCAFFOLD (Phase 6): the real handlers + the templ/htmx admin UI (OpenDesign
// tokens §11.4.162, host-rendered pixel proof §11.4.170) land here in plan
// T6.1/T6.2. main() today only wires the contracts + prints a version/usage line.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"digital.vasic.helixproxy/controlplane/internal/api"
	"digital.vasic.helixproxy/controlplane/internal/otel"
	"digital.vasic.helixproxy/controlplane/internal/pac"
	"digital.vasic.helixproxy/controlplane/internal/store"
)

const version = "0.0.0-scaffold"

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	addr := flag.String("addr", ":58080", "control-API listen address")
	flag.Parse()
	if *showVersion {
		fmt.Println("api", version)
		return
	}

	shutdown, _ := otel.Init(context.Background(), "api")
	defer func() { _ = shutdown(context.Background()) }()

	// SCAFFOLD (Phase 6): construct an api.Server (backed by store.Queries +
	// pac.Generator) and call Start(ctx) (plan T6.1/T6.2). The config + contract
	// declarations below pin the wiring.
	_ = api.Config{Addr: *addr}
	var (
		_ api.Server
		_ store.Queries
		_ pac.Generator
	)

	fmt.Fprintln(os.Stderr, "api "+version+": SCAFFOLD — control-API + admin UI not yet implemented (plan Phase 6)")
	fmt.Fprintf(os.Stderr, "usage: api [--version] [--addr %s]\n", *addr)
}
