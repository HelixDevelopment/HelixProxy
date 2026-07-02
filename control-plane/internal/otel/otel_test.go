package otel

import (
	"context"
	"errors"
	"testing"
)

// TestInit_ReturnsUsableShutdownAndNoError asserts the core contract callers
// depend on: Init hands back a NON-NIL ShutdownFunc and a NIL error, so
// `defer shutdown(ctx)` wired at call sites is always safe.
//
// A bug that returned a nil ShutdownFunc (the deferred call would panic) or a
// non-nil error (callers would abort startup) breaks this test.
func TestInit_ReturnsUsableShutdownAndNoError(t *testing.T) {
	shutdown, err := Init(context.Background(), "control-plane")
	if err != nil {
		t.Fatalf("Init returned error %v, want nil", err)
	}
	if shutdown == nil {
		t.Fatal("Init returned a nil ShutdownFunc; callers rely on it being callable")
	}
}

// TestShutdown_IsNoOpAndReturnsNil asserts the returned hook actually runs
// without panicking and reports success (nil). A scaffold that returned nil
// error is the guarantee here; a bug returning an error, or a hook that
// dereferenced an unset provider (panic), breaks this test.
func TestShutdown_IsNoOpAndReturnsNil(t *testing.T) {
	shutdown, err := Init(context.Background(), "svc")
	if err != nil {
		t.Fatalf("Init returned error %v, want nil", err)
	}
	if got := shutdown(context.Background()); got != nil {
		t.Fatalf("shutdown() = %v, want nil", got)
	}
}

// TestShutdown_Idempotent asserts the hook is safe to call more than once
// (double-shutdown / retry paths). Each call must return nil and not panic.
//
// A bug that closed a channel or freed a provider on the first call and then
// panicked/errored on the second breaks this test.
func TestShutdown_Idempotent(t *testing.T) {
	shutdown, err := Init(context.Background(), "svc")
	if err != nil {
		t.Fatalf("Init returned error %v, want nil", err)
	}
	for i := 0; i < 3; i++ {
		if got := shutdown(context.Background()); got != nil {
			t.Fatalf("shutdown() call #%d = %v, want nil", i+1, got)
		}
	}
}

// TestShutdown_HonoursCancelledContext asserts the hook is well-behaved when
// handed an already-cancelled context (the realistic shutdown-during-teardown
// case). The scaffold ignores the context and returns nil; it must not
// propagate ctx.Err() as a failure. A bug that plumbed the cancelled context
// into a flush and surfaced context.Canceled breaks this test.
func TestShutdown_HonoursCancelledContext(t *testing.T) {
	shutdown, err := Init(context.Background(), "svc")
	if err != nil {
		t.Fatalf("Init returned error %v, want nil", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if got := shutdown(ctx); got != nil {
		t.Fatalf("shutdown(cancelled ctx) = %v, want nil", got)
	}
}

// TestInit_EmptyServiceName asserts Init does not reject an empty service name
// in the scaffold (no validation error today). This pins current behavior: a
// future change that starts validating serviceName must update this test
// deliberately rather than silently break callers passing "".
func TestInit_EmptyServiceName(t *testing.T) {
	shutdown, err := Init(context.Background(), "")
	if err != nil {
		t.Fatalf("Init(\"\") returned error %v, want nil", err)
	}
	if shutdown == nil {
		t.Fatal("Init(\"\") returned a nil ShutdownFunc")
	}
	if got := shutdown(context.Background()); got != nil {
		t.Fatalf("shutdown() after empty-name Init = %v, want nil", got)
	}
}

// TestInit_TolerantOfNilContext asserts the scaffold ignores the ctx argument
// (it is documented to never error) and does not dereference it. A bug that
// derived a child context from a nil parent would panic; this test catches it.
func TestInit_TolerantOfNilContext(t *testing.T) {
	//nolint:staticcheck // SA1012: intentionally exercising the nil-ctx edge.
	shutdown, err := Init(nil, "svc")
	if err != nil {
		t.Fatalf("Init(nil ctx) returned error %v, want nil", err)
	}
	if shutdown == nil {
		t.Fatal("Init(nil ctx) returned a nil ShutdownFunc")
	}
}

// TestInit_IndependentShutdownHooks asserts two Init calls hand back
// independent, individually-usable hooks (no shared/global state that a second
// Init would clobber). Both must succeed independently.
//
// A bug that stored the hook in a package-global and had the second Init
// overwrite/invalidate the first's hook breaks this test.
func TestInit_IndependentShutdownHooks(t *testing.T) {
	s1, err1 := Init(context.Background(), "svc-a")
	if err1 != nil {
		t.Fatalf("first Init error %v, want nil", err1)
	}
	s2, err2 := Init(context.Background(), "svc-b")
	if err2 != nil {
		t.Fatalf("second Init error %v, want nil", err2)
	}
	if got := s1(context.Background()); got != nil {
		t.Fatalf("first shutdown = %v, want nil", got)
	}
	if got := s2(context.Background()); got != nil {
		t.Fatalf("second shutdown = %v, want nil", got)
	}
}

// TestShutdownFunc_TypeSatisfiesContract asserts ShutdownFunc has the exact
// signature callers store (func(context.Context) error) by assigning a value
// of that literal type and invoking it. A change to the type's signature would
// fail compilation of this test — a compile-time guard on the public type.
func TestShutdownFunc_TypeSatisfiesContract(t *testing.T) {
	var fn ShutdownFunc = func(context.Context) error { return errors.New("boom") }
	if got := fn(context.Background()); got == nil {
		t.Fatal("ShutdownFunc did not return the error it was defined to return")
	}
}
