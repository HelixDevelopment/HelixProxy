// Package otel wires OpenTelemetry tracing + metrics for the Go control-plane
// (design spec §11 ③). In-process OTel/metrics are the chosen observability path;
// eBPF is deliberately rejected because it needs kernel privileges and breaks the
// rootless mandate (spec §11 deferred list, §11.4.161).
//
// SCAFFOLD (Phase 7): real provider setup (OTLP exporter, tracer + meter
// providers) lands in internal/otel during plan T7.2. Init is intentionally a
// no-op today so callers can wire `defer shutdown(ctx)` now and get the real
// behaviour for free once Phase 7 lands.
package otel

import "context"

// ShutdownFunc flushes and releases telemetry providers. It is always safe to
// call (the scaffold returns a no-op).
type ShutdownFunc func(context.Context) error

// Init installs the global tracer/meter providers for the named service and
// returns a shutdown hook.
//
// SCAFFOLD (Phase 7): real OTel provider wiring lands here (plan T7.2). For now
// it returns a no-op shutdown and never errors.
func Init(ctx context.Context, serviceName string) (ShutdownFunc, error) {
	_ = ctx
	_ = serviceName
	return func(context.Context) error { return nil }, nil
}
