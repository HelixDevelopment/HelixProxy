// Command acl-helper is the Squid external_acl_type helper (design spec §4
// component 3, plan Phase 5): for each request it reads Redis {target->tunnel,
// up?} and emits `OK tag=<tunnel>` (allow that cache_peer) or `ERR` (-> Squid
// `deny_info 503`). It embeds the circuit-breaker + tunnel tier-failover decision
// and fails closed so a tunnel outage yields a graceful 503, never a leak.
//
// SCAFFOLD (Phase 5): the real stdin/stdout ACL protocol loop lands here in plan
// T5.1/T5.2. main() today only wires the contracts + prints a version/usage line.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"digital.vasic.helixproxy/controlplane/internal/breaker"
	"digital.vasic.helixproxy/controlplane/internal/otel"
	"digital.vasic.helixproxy/controlplane/internal/redis"
)

const version = "0.0.0-scaffold"

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("acl-helper", version)
		return
	}

	shutdown, _ := otel.Init(context.Background(), "acl-helper")
	defer func() { _ = shutdown(context.Background()) }()

	// SCAFFOLD (Phase 5): construct a redis.StatusBus + breaker.Decider, then run
	// the per-request external_acl_type loop on stdin/stdout (plan T5.1/T5.2).
	var (
		_ redis.StatusBus
		_ breaker.Decider
	)

	fmt.Fprintln(os.Stderr, "acl-helper "+version+": SCAFFOLD — external-acl-helper not yet implemented (plan Phase 5)")
	fmt.Fprintln(os.Stderr, "usage: acl-helper [--version]   (Squid external_acl_type stdin/stdout protocol)")
}
