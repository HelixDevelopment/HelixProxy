// Command healthd is the vpn-health-publisher (design spec §4 component 1, plan
// Phase 3): per profile it polls the gluetun control API, reads the
// `wg show <if> transfer` byte-delta, runs an egress probe, then writes
// vpn:status:<profile> and publishes vpn:events. Health is a DATA-PLANE FACT,
// never "configured" (§11.4.107 / §11.4.69).
//
// SCAFFOLD (Phase 3): the real per-profile poll loop lands here in plan
// T3.1/T3.2. main() today only wires the package contracts + prints a
// version/usage line — no business logic.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"digital.vasic.helixproxy/controlplane/internal/otel"
	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

const version = "0.0.0-scaffold"

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("healthd", version)
		return
	}

	shutdown, _ := otel.Init(context.Background(), "healthd")
	defer func() { _ = shutdown(context.Background()) }()

	// SCAFFOLD (Phase 3): construct a vpn.Prober + vpn.HealthEvaluator and a
	// redis.StatusBus (vpn.Publisher), then run the per-profile poll loop
	// (plan T3.1/T3.2). The declarations below pin the wiring contracts.
	var (
		_ vpn.Prober
		_ vpn.HealthEvaluator
		_ vpn.Publisher
		_ redis.StatusBus
	)

	fmt.Fprintln(os.Stderr, "healthd "+version+": SCAFFOLD — vpn-health-publisher not yet implemented (plan Phase 3)")
	fmt.Fprintln(os.Stderr, "usage: healthd [--version]")
}
