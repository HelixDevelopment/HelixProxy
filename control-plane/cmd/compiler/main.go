// Command compiler is the config-compiler (design spec §4 component 2, plan
// Phase 4): it reads the Postgres data model and renders the Squid generated
// include, the Dante route config, and the PAC file, then applies them (writes to
// the configured paths) and seeds the resolved `route:<target>` decisions into
// Redis (spec §7). Up/down is applied via the external-acl helper + Redis per
// request; ONLY structural changes (a tunnel/target added or removed) warrant a
// Squid `reconfigure` / Dante SIGHUP (spec §8 / §9). This binary renders + writes;
// the structural reload itself is an operator/orchestrator step.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"digital.vasic.helixproxy/controlplane/internal/otel"
	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/routing"
	"digital.vasic.helixproxy/controlplane/internal/store"
)

const version = "0.1.0"

// DefaultHelperPath is the deployed external_acl helper binary path the rendered
// Squid include wires (overridable via --helper-path).
const DefaultHelperPath = "/usr/lib/helix-proxy/acl-helper"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "compiler:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("compiler", flag.ContinueOnError)
	var (
		showVersion = fs.Bool("version", false, "print version and exit")
		dsn         = fs.String("dsn", os.Getenv("HELIX_PG_DSN"), "PostgreSQL DSN (or $HELIX_PG_DSN)")
		redisAddr   = fs.String("redis-addr", os.Getenv("HELIX_REDIS_ADDR"), "Redis addr for route:<target> seeding; empty = skip seeding")
		helperPath  = fs.String("helper-path", DefaultHelperPath, "absolute path to the external_acl helper binary")
		pacProxy    = fs.String("pac-proxy", routing.DefaultPACProxy, "PAC return value for routed targets")
		squidOut    = fs.String("squid-out", "", "write the rendered Squid include to this path")
		danteBase   = fs.String("dante-base", "", "shipped sockd.conf read verbatim and prepended to the rendered Dante routes")
		danteOut    = fs.String("dante-out", "", "write the concatenated deployed sockd.conf to this path")
		pacOut      = fs.String("pac-out", "", "write the rendered PAC file to this path")
	)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *showVersion {
		fmt.Println("compiler", version)
		return nil
	}
	if *dsn == "" {
		return fmt.Errorf("--dsn (or $HELIX_PG_DSN) is required")
	}

	ctx := context.Background()
	shutdown, _ := otel.Init(ctx, "compiler")
	defer func() { _ = shutdown(ctx) }()

	pg, err := store.Open(ctx, *dsn)
	if err != nil {
		return fmt.Errorf("open store: %w", err)
	}
	defer func() { _ = pg.Close() }()

	eng := routing.New(*helperPath, *pacProxy)
	arts, routes, err := eng.CompileAll(ctx, pg)
	if err != nil {
		return fmt.Errorf("compile: %w", err)
	}

	if *squidOut != "" {
		if err := writeFile(*squidOut, arts.SquidInclude); err != nil {
			return err
		}
	}
	if *danteOut != "" {
		deployed := arts.DanteRoutes
		if *danteBase != "" {
			base, berr := os.ReadFile(*danteBase)
			if berr != nil {
				return fmt.Errorf("read dante base %s: %w", *danteBase, berr)
			}
			// Concatenation, not include: base verbatim + a separator + routes (§9).
			deployed = append(append(append([]byte{}, base...), []byte("\n")...), arts.DanteRoutes...)
		}
		if err := writeFile(*danteOut, deployed); err != nil {
			return err
		}
	}
	if *pacOut != "" {
		if err := writeFile(*pacOut, arts.PAC); err != nil {
			return err
		}
	}

	seeded := 0
	if *redisAddr != "" {
		rc, rerr := redis.Open(ctx, *redisAddr, 0)
		if rerr != nil {
			return fmt.Errorf("open redis %s: %w", *redisAddr, rerr)
		}
		defer func() { _ = rc.Close() }()
		for _, r := range routes {
			if err := rc.SetRoute(ctx, r); err != nil {
				return fmt.Errorf("seed route %s: %w", r.Target, err)
			}
			seeded++
		}
	}

	fmt.Printf("compiler %s: rendered squid(%dB) dante(%dB) pac(%dB); resolved %d route(s), seeded %d to redis\n",
		version, len(arts.SquidInclude), len(arts.DanteRoutes), len(arts.PAC), len(routes), seeded)
	return nil
}

// writeFile creates parent dirs then writes b (0644) to path.
func writeFile(path string, b []byte) error {
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", dir, err)
		}
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}
