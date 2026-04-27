# AGENTS.md

Guidelines for AI coding agents working in this repository.

## Project Overview

This is a Bash/Docker/Podman-based project. Scripts manage containerized workloads and infrastructure automation.

## Build/Run/Test Commands

### Shell Scripts

```bash
# Lint all shell scripts
shellcheck scripts/*.sh

# Lint a single file
shellcheck scripts/proxy.sh

# Format shell scripts (requires shfmt)
shfmt -w scripts/*.sh

# Run a script
./scripts/proxy.sh [args]

# Test with bats (if tests exist)
bats test/*.bats

# Run a single test file
bats test/proxy.bats

# Run specific test by name
bats -f "test name pattern" test/proxy.bats
```

### Docker

```bash
# Build image
docker build -t proxy:latest .

# Build with no cache
docker build --no-cache -t proxy:latest .

# Run container
docker run -d --name proxy proxy:latest

# View logs
docker logs -f proxy

# Stop and remove
docker stop proxy && docker rm proxy

# Compose up
docker compose up -d

# Compose down
docker compose down

# Execute in container
docker exec -it proxy /bin/sh
```

### Podman

```bash
# Build image
podman build -t proxy:latest .

# Run container
podman run -d --name proxy proxy:latest

# Podman compose (if available)
podman-compose up -d

# Pod operations
podman pod create --name proxy-pod
podman pod start proxy-pod
podman pod stop proxy-pod
```

## Code Style Guidelines

### Shell Scripts (Bash)

```bash
#!/usr/bin/env bash
# Always use bash with env for portability

set -euo pipefail
# -e: Exit on error
# -u: Error on undefined variables
# -o pipefail: Pipeline fails on first error

# Script metadata as comments at top
# Description: What this script does
# Usage: ./script.sh [args]

#######################################
# Function description
# Globals:
#   VAR_NAME - description
# Arguments:
#   $1 - first arg description
# Outputs:
#   Writes to stdout
# Returns:
#   0 on success, non-zero on failure
#######################################
function_name() {
    local var="$1"
    
    # Prefer [[ ]] over [ ]
    if [[ -n "$var" ]]; then
        echo "$var"
    fi
}

# Main entry point
main() {
    function_name "$@"
}

main "$@"
```

### Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Variables | snake_case | `container_name` |
| Constants | UPPER_SNAKE | `MAX_RETRIES` |
| Functions | snake_case | `build_image()` |
| Scripts | kebab-case | `start-proxy.sh` |
| Directories | lowercase | `scripts/`, `config/` |

### Variable Declarations

```bash
# Always quote variables
local name="$1"
local path="${HOME}/config"

# Readonly for constants
readonly DEFAULT_PORT=8080
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Arrays
local containers=("web" "api" "db")
local -A config=(["host"]="localhost" ["port"]="8080")
```

### Error Handling

```bash
# Exit with meaningful codes
exit 1   # General error
exit 2   # Misuse of command
exit 126 # Command not executable
exit 127 # Command not found

# Error function
error() {
    echo "[ERROR] $1" >&2
    exit "${2:-1}"
}

# Trap for cleanup
cleanup() {
    docker stop "$container" 2>/dev/null || true
}
trap cleanup EXIT
```

### Dockerfile Style

```dockerfile
# syntax=docker/dockerfile:1

# Use specific versions, not :latest
FROM alpine:3.19

# Labels for metadata
LABEL maintainer="team@example.com"
LABEL version="1.0"
LABEL description="Proxy service"

# Combine RUN commands to reduce layers
RUN apk add --no-cache \
    curl \
    bash \
    && rm -rf /var/cache/apk/*

# Use COPY over ADD
COPY scripts/ /app/scripts/

# Non-root user when possible
RUN adduser -D appuser
USER appuser

# Explicit entrypoint and cmd
ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["--help"]
```

### Docker Compose Style

```yaml
version: "3.8"

services:
  proxy:
    build:
      context: .
      dockerfile: Dockerfile
    image: proxy:latest
    container_name: proxy
    restart: unless-stopped
    environment:
      - LOG_LEVEL=info
    volumes:
      - ./config:/config:ro
    ports:
      - "8080:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - proxy-net

networks:
  proxy-net:
    driver: bridge
```

## Project Structure

```
.
├── scripts/           # Shell scripts
│   ├── build.sh       # Build script
│   ├── deploy.sh      # Deploy script
│   └── utils.sh       # Shared functions
├── config/            # Configuration files
├── docker/            # Docker-related files
│   ├── Dockerfile
│   └── docker-compose.yml
├── test/              # Test files (*.bats)
├── .env.example       # Environment template
└── Makefile           # Common commands
```

## Best Practices

1. **Scripts**: Always include `set -euo pipefail` and a usage function
2. **Docker**: Use multi-stage builds for smaller images
3. **Security**: Never hardcode secrets; use environment variables
4. **Logging**: Use structured logging with timestamps
5. **Idempotency**: Scripts should be safe to run multiple times
6. **Documentation**: Comment complex logic; document exit codes

## Common Patterns

```bash
# Check dependencies
command -v docker >/dev/null 2>&1 || error "docker is required"
command -v podman >/dev/null 2>&1 || error "podman is required"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -v|--verbose) VERBOSE=1; shift ;;
        *) error "Unknown option: $1" ;;
    esac
done

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    error "Do not run as root"
fi

# Retry logic
retry() {
    local max="$1"
    local cmd="${@:2}"
    local n=0
    until "$cmd"; do
        ((n++))
        [[ $n -ge $max ]] && error "Failed after $max attempts"
        sleep 2
    done
}
```



---

## Universal Mandatory Constraints

> Cascaded from the HelixAgent root `CLAUDE.md` via `/tmp/UNIVERSAL_MANDATORY_RULES.md`.
> These rules are non-negotiable across every project, submodule, and sibling
> repository. Project-specific addenda are welcome but cannot weaken or
> override these.

### Hard Stops (permanent, non-negotiable)

1. **NO CI/CD pipelines.** No `.github/workflows/`, `.gitlab-ci.yml`,
   `Jenkinsfile`, `.travis.yml`, `.circleci/`, or any automated pipeline.
   No Git hooks either. All builds and tests run manually or via
   Makefile/script targets.
2. **NO HTTPS for Git.** SSH URLs only (`git@github.com:…`,
   `git@gitlab.com:…`, etc.) for clones, fetches, pushes, and submodule
   updates. Including for public repos. SSH keys are configured on every
   service.
3. **NO manual container commands.** Container orchestration is owned by
   the project's binary/orchestrator (e.g. `make build` → `./bin/<app>`).
   Direct `docker`/`podman start|stop|rm` and `docker-compose up|down`
   are prohibited as workflows. The orchestrator reads its configured
   `.env` and brings up everything.

### Mandatory Development Standards

1. **100% Test Coverage.** Every component MUST have unit, integration,
   E2E, automation, security/penetration, and benchmark tests. No false
   positives. Mocks/stubs ONLY in unit tests; all other test types use
   real data and live services.
2. **Challenge Coverage.** Every component MUST have Challenge scripts
   (`./challenges/scripts/`) validating real-life use cases. No false
   success — validate actual behavior, not return codes.
3. **Real Data.** Beyond unit tests, all components MUST use actual API
   calls, real databases, live services. No simulated success. Fallback
   chains tested with actual failures.
4. **Health & Observability.** Every service MUST expose health
   endpoints. Circuit breakers for all external dependencies.
   Prometheus / OpenTelemetry integration where applicable.
5. **Documentation & Quality.** Update `CLAUDE.md`, `AGENTS.md`, and
   relevant docs alongside code changes. Pass language-appropriate
   format/lint/security gates. Conventional Commits:
   `<type>(<scope>): <description>`.
6. **Validation Before Release.** Pass the project's full validation
   suite (`make ci-validate-all`-equivalent) plus all challenges
   (`./challenges/scripts/run_all_challenges.sh`).
7. **No Mocks or Stubs in Production.** Mocks, stubs, fakes,
   placeholder classes, TODO implementations are STRICTLY FORBIDDEN in
   production code. All production code is fully functional with real
   integrations. Only unit tests may use mocks/stubs.
8. **Comprehensive Verification.** Every fix MUST be verified from all
   angles: runtime testing (actual HTTP requests / real CLI
   invocations), compile verification, code structure checks,
   dependency existence checks, backward compatibility, and no false
   positives in tests or challenges. Grep-only validation is NEVER
   sufficient.
9. **Resource Limits for Tests & Challenges (CRITICAL).** ALL test and
   challenge execution MUST be strictly limited to 30-40% of host
   system resources. Use `GOMAXPROCS=2`, `nice -n 19`, `ionice -c 3`,
   `-p 1` for `go test`. Container limits required. The host runs
   mission-critical processes — exceeding limits causes system crashes.
10. **Bugfix Documentation.** All bug fixes MUST be documented in
    `docs/issues/fixed/BUGFIXES.md` (or the project's equivalent) with
    root cause analysis, affected files, fix description, and a link to
    the verification test/challenge.
11. **Real Infrastructure for All Non-Unit Tests.** Mocks/fakes/stubs/
    placeholders MAY be used ONLY in unit tests (files ending
    `_test.go` run under `go test -short`, equivalent for other
    languages). ALL other test types — integration, E2E, functional,
    security, stress, chaos, challenge, benchmark, runtime
    verification — MUST execute against the REAL running system with
    REAL containers, REAL databases, REAL services, and REAL HTTP
    calls. Non-unit tests that cannot connect to real services MUST
    skip (not fail).
12. **Reproduction-Before-Fix (CONST-032 — MANDATORY).** Every reported
    error, defect, or unexpected behavior MUST be reproduced by a
    Challenge script BEFORE any fix is attempted. Sequence:
    (1) Write the Challenge first. (2) Run it; confirm fail (it
    reproduces the bug). (3) Then write the fix. (4) Re-run; confirm
    pass. (5) Commit Challenge + fix together. The Challenge becomes
    the regression guard for that bug forever.
13. **Concurrent-Safe Containers (Go-specific, where applicable).** Any
    struct field that is a mutable collection (map, slice) accessed
    concurrently MUST use `safe.Store[K,V]` / `safe.Slice[T]` from
    `digital.vasic.concurrency/pkg/safe` (or the project's equivalent
    primitives). Bare `sync.Mutex + map/slice` combinations are
    prohibited for new code.

### Definition of Done (universal)

A change is NOT done because code compiles and tests pass. "Done"
requires pasted terminal output from a real run, produced in the same
session as the change.

- **No self-certification.** Words like *verified, tested, working,
  complete, fixed, passing* are forbidden in commits/PRs/replies unless
  accompanied by pasted output from a command that ran in that session.
- **Demo before code.** Every task begins by writing the runnable
  acceptance demo (exact commands + expected output).
- **Real system, every time.** Demos run against real artifacts.
- **Skips are loud.** `t.Skip` / `@Ignore` / `xit` / `describe.skip`
  without a trailing `SKIP-OK: #<ticket>` comment break validation.
- **Evidence in the PR.** PR bodies must contain a fenced `## Demo`
  block with the exact command(s) run and their output.

<!-- BEGIN host-power-management addendum (CONST-033) -->

## Host Power Management — Hard Ban (CONST-033)

**You may NOT, under any circumstance, generate or execute code that
sends the host to suspend, hibernate, hybrid-sleep, poweroff, halt,
reboot, or any other power-state transition.** This rule applies to:

- Every shell command you run via the Bash tool.
- Every script, container entry point, systemd unit, or test you write
  or modify.
- Every CLI suggestion, snippet, or example you emit.

**Forbidden invocations** (non-exhaustive — see CONST-033 in
`CONSTITUTION.md` for the full list):

- `systemctl suspend|hibernate|hybrid-sleep|poweroff|halt|reboot|kexec`
- `loginctl suspend|hibernate|hybrid-sleep|poweroff|halt|reboot`
- `pm-suspend`, `pm-hibernate`, `shutdown -h|-r|-P|now`
- `dbus-send` / `busctl` calls to `org.freedesktop.login1.Manager.Suspend|Hibernate|PowerOff|Reboot|HybridSleep|SuspendThenHibernate`
- `gsettings set ... sleep-inactive-{ac,battery}-type` to anything but `'nothing'` or `'blank'`

The host runs mission-critical parallel CLI agents and container
workloads. Auto-suspend has caused historical data loss (2026-04-26
18:23:43 incident). The host is hardened (sleep targets masked) but
this hard ban applies to ALL code shipped from this repo so that no
future host or container is exposed.

**Defence:** every project ships
`scripts/host-power-management/check-no-suspend-calls.sh` (static
scanner) and
`challenges/scripts/no_suspend_calls_challenge.sh` (challenge wrapper).
Both MUST be wired into the project's CI / `run_all_challenges.sh`.

**Full background:** `docs/HOST_POWER_MANAGEMENT.md` and `CONSTITUTION.md` (CONST-033).

<!-- END host-power-management addendum (CONST-033) -->

