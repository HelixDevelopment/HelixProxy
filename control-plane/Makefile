# Helix Proxy control-plane — Go module dev targets.
#
# SCAFFOLD (plan T0.5). These targets are DEV-CONVENIENCE ONLY.
#
# §11.4.173 — the PRODUCTION build MUST run inside a build container provisioned
# via the `vasic-digital/containers` submodule on the remote build host, with the
# produced artifacts brought back. NEVER treat a bare-host `go build` as a release
# artifact. The containerized/distributed build wiring lands in plan T0.4.
#
# Resource discipline (§11.4 dev-standards / §12.6): keep test/build load bounded
# on the shared host — prefix heavy `go test` runs with GOMAXPROCS + nice/ionice.

GO ?= go

.PHONY: all fmt fmt-check vet build test tidy clean help

all: fmt-check vet build ## fmt-check + vet + build

fmt: ## format all Go sources in place
	gofmt -w .

fmt-check: ## list files needing formatting (empty output == clean)
	@out="$$(gofmt -l .)"; \
	if [ -n "$$out" ]; then echo "gofmt needs to run on:"; echo "$$out"; exit 1; fi; \
	echo "gofmt: clean"

vet: ## go vet the whole module
	$(GO) vet ./...

build: ## build all packages + commands (dev convenience; see §11.4.173 for prod)
	$(GO) build ./...

test: ## run unit tests (none in the scaffold yet)
	GOMAXPROCS=2 nice -n 19 $(GO) test ./...

tidy: ## sync go.mod/go.sum
	$(GO) mod tidy

clean: ## remove local build cache artifacts
	$(GO) clean ./...

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'
