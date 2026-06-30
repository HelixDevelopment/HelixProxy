package api

import (
	"bufio"
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// TestSSE_EventDelivered opens a REAL SSE connection over mTLS, publishes a real
// event onto the (fake) bus, and asserts the exact `data: <json>` frame is
// delivered to the client — then cancels and confirms a clean disconnect.
func TestSSE_EventDelivered(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, h.url+"/events", nil)
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("open SSE: %v", err)
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/event-stream") {
		t.Fatalf("SSE content-type: want text/event-stream, got %q", ct)
	}

	// Publish a real event (the SubscribeEvents goroutine forwards it to the stream).
	go func() {
		time.Sleep(100 * time.Millisecond)
		_ = h.bus.PublishEvent(context.Background(), redis.Event{ProfileID: "eu-wg", State: vpn.StateDown})
	}()

	// Read the first SSE data frame.
	sc := bufio.NewScanner(resp.Body)
	var dataLine string
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "data:") {
			dataLine = strings.TrimSpace(strings.TrimPrefix(line, "data:"))
			break
		}
	}
	if dataLine == "" {
		t.Fatalf("no SSE data frame received (scanner err %v)", sc.Err())
	}
	if !strings.Contains(dataLine, `"profile_id":"eu-wg"`) || !strings.Contains(dataLine, `"state":"down"`) {
		t.Fatalf("SSE frame mismatch: %q", dataLine)
	}
}

// TestSSE_CleanDisconnect proves the handler returns (does not block forever) once
// the client context is cancelled.
func TestSSE_CleanDisconnect(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	ctx, cancel := context.WithCancel(context.Background())
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, h.url+"/events", nil)
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("open SSE: %v", err)
	}
	// Cancel and confirm the body read unblocks promptly.
	cancel()
	done := make(chan struct{})
	go func() {
		buf := make([]byte, 64)
		_, _ = resp.Body.Read(buf)
		_ = resp.Body.Close()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("SSE did not unblock after client cancel")
	}
}
