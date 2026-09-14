package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

func TestDelayEventFilterKeepsConcurrentManualTargetsScoped(t *testing.T) {
	var filter delayEventFilter
	first := filter.begin("node", "https://example.com")
	second := filter.begin("node", "https://example.com")

	if got := filter.message("https://example.com", "node", 0); got != nil {
		t.Fatalf("manual failure leaked as event: %+v", got)
	}
	if got := filter.message("https://other.example.com", "node", 25); got == nil || got.Value != 25 {
		t.Fatalf("independent URL event = %+v", got)
	}
	if got := filter.message("https://example.com", "other", 25); got == nil || got.Value != 25 {
		t.Fatalf("independent proxy event = %+v", got)
	}

	first()
	if got := filter.message("https://example.com", "node", 0); got != nil {
		t.Fatalf("second manual probe still active, event = %+v", got)
	}
	second()
	if got := filter.message("https://example.com", "node", 0); got == nil || got.Value != -1 {
		t.Fatalf("background failure after manual completion = %+v", got)
	}
	if len(filter.active) != 0 {
		t.Fatalf("completed manual probes retained %d targets", len(filter.active))
	}
}

func TestDelayEventFilterConcurrentAccess(t *testing.T) {
	var filter delayEventFilter
	var workers sync.WaitGroup
	for range 50 {
		workers.Go(func() {
			for range 100 {
				finish := filter.begin("node", "https://example.com")
				if got := filter.message("https://example.com", "node", 25); got != nil {
					t.Error("manual probe event escaped while its slot was active")
				}
				finish()
			}
		})
	}
	workers.Wait()
	if len(filter.active) != 0 {
		t.Fatalf("completed manual probes retained %d targets", len(filter.active))
	}
}

type delayProbeProxy struct {
	constant.Proxy
	onTest func(context.Context, string) (uint16, error)
}

func (p *delayProbeProxy) Name() string { return "node" }

func (p *delayProbeProxy) URLTest(ctx context.Context, url string, _ utils.IntRanges[uint16]) (uint16, error) {
	return p.onTest(ctx, url)
}

func TestHandleAsyncTestDelayReturnsScopedResultWithoutDuplicateEvent(t *testing.T) {
	previousProxies, previousProviders := tunnel.Proxies(), tunnel.Providers()
	t.Cleanup(func() { tunnel.UpdateProxies(previousProxies, previousProviders) })

	for _, probe := range []struct {
		value   uint16
		failure bool
		want    int32
	}{
		{value: 25, want: 25},
		{value: 0, want: 1},
		{value: 0, failure: true, want: -1},
	} {
		proxy := &delayProbeProxy{onTest: func(ctx context.Context, url string) (uint16, error) {
			if _, ok := ctx.Deadline(); !ok {
				t.Error("manual probe has no network deadline")
			}
			if got := manualDelayEvents.message(url, "node", 0); got != nil {
				t.Errorf("manual URLTest event was not suppressed: %+v", got)
			}
			if probe.failure {
				return probe.value, errors.New("unreachable")
			}
			return probe.value, nil
		}}
		tunnel.UpdateProxies(map[string]constant.Proxy{"node": proxy}, nil)
		result := make(chan *Delay, 1)
		handleAsyncTestDelay(&TestDelayParams{
			ProxyName: "node", TestUrl: "https://example.com", Timeout: 5000,
		}, func(delay *Delay) { result <- delay })

		select {
		case got := <-result:
			if got.Name != "node" || got.Url != "https://example.com" || got.Value != probe.want {
				t.Fatalf("manual response = %+v, want node, supplied URL, %d", got, probe.want)
			}
			if got := manualDelayEvents.message("https://example.com", "node", 25); got == nil {
				t.Fatal("background event still suppressed after the manual result")
			}
		case <-time.After(time.Second):
			t.Fatal("manual probe did not respond")
		}
	}
}

func TestHandleAsyncTestDelayPreservesURLForMissingProxy(t *testing.T) {
	previousProxies, previousProviders := tunnel.Proxies(), tunnel.Providers()
	t.Cleanup(func() { tunnel.UpdateProxies(previousProxies, previousProviders) })
	tunnel.UpdateProxies(map[string]constant.Proxy{}, nil)

	for _, url := range []string{"https://example.com", ""} {
		result := make(chan *Delay, 1)
		handleAsyncTestDelay(&TestDelayParams{
			ProxyName: "missing", TestUrl: url, Timeout: 5000,
		}, func(delay *Delay) { result <- delay })
		wantURL := url
		if wantURL == "" {
			wantURL = constant.DefaultTestURL
		}
		select {
		case got := <-result:
			if got.Name != "missing" || got.Url != wantURL || got.Value != -1 {
				t.Fatalf("missing proxy response = %+v, want missing, %q, -1", got, wantURL)
			}
		case <-time.After(time.Second):
			t.Fatal("missing proxy did not respond")
		}
	}
}

// Exercise the real outbound HTTP probe, not a synthetic returned delay. A slow
// link must stay failed at its first deadline and recover with the retry budget.
func TestDelayProbeRetriesSlowHTTPWithItsOwnBudget(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
			return
		case <-time.After(150 * time.Millisecond):
			w.WriteHeader(http.StatusNoContent)
		}
	}))
	defer server.Close()
	previousProxies, previousProviders := tunnel.Proxies(), tunnel.Providers()
	t.Cleanup(func() { tunnel.UpdateProxies(previousProxies, previousProviders) })
	tunnel.UpdateProxies(map[string]constant.Proxy{"slow": adapter.NewProxy(outbound.NewDirect())}, nil)
	for _, timeout := range []int64{30, 2000} {
		result := make(chan *Delay, 1)
		handleAsyncTestDelay(&TestDelayParams{
			ProxyName: "slow", TestUrl: server.URL, Timeout: timeout,
		}, func(delay *Delay) { result <- delay })
		select {
		case delay := <-result:
			if timeout == 30 && delay.Value != -1 {
				t.Fatalf("short deadline reported success: %+v", delay)
			}
			if timeout == 2000 && delay.Value <= 0 {
				t.Fatalf("larger retry budget did not recover the slow HTTP probe: %+v", delay)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("probe did not finish within its RPC grace")
		}
	}
}
