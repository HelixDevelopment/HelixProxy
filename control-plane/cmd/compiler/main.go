// Command compiler is the config-compiler (design spec §4 component 2, plan
// Phase 4): it reads the Postgres data model and renders the Squid generated
// include, the Dante route config, and the PAC file, then applies them. Up/down
// is applied via Redis per request; only STRUCTURAL changes trigger a Squid
// reconfigure / Dante SIGHUP (spec §8 / §9).
//
// SCAFFOLD (Phase 4): the real compile + apply lands here in plan T4.1–T4.3.
// main() today only wires the contracts + prints a version/usage line.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"digital.vasic.helixproxy/controlplane/internal/otel"
	"digital.vasic.helixproxy/controlplane/internal/routing"
	"digital.vasic.helixproxy/controlplane/internal/store"
)

const version = "0.0.0-scaffold"

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("compiler", version)
		return
	}

	shutdown, _ := otel.Init(context.Background(), "compiler")
	defer func() { _ = shutdown(context.Background()) }()

	// SCAFFOLD (Phase 4): construct a store.Queries + routing.Compiler, render
	// routing.Artifacts, and apply them (structural reload only) (plan T4.1–T4.3).
	var (
		_ store.Queries
		_ routing.Compiler
	)

	fmt.Fprintln(os.Stderr, "compiler "+version+": SCAFFOLD — config-compiler not yet implemented (plan Phase 4)")
	fmt.Fprintln(os.Stderr, "usage: compiler [--version]")
}
