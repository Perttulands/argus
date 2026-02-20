package watchdog

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestRunCycleContinuesAfterErrorAndPanic(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	wd, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
		DryRun:         true,
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	var executed []string
	wd.SetChecks([]Check{
		{
			Name: "returns-error",
			Run: func(ctx context.Context, dryRun bool) error {
				_ = ctx
				if !dryRun {
					t.Fatal("dry-run flag was not propagated to check")
				}
				executed = append(executed, "returns-error")
				return errors.New("synthetic failure")
			},
		},
		{
			Name: "panics",
			Run: func(ctx context.Context, dryRun bool) error {
				_ = ctx
				_ = dryRun
				executed = append(executed, "panics")
				panic("boom")
			},
		},
		{
			Name: "still-runs",
			Run: func(ctx context.Context, dryRun bool) error {
				_ = ctx
				_ = dryRun
				executed = append(executed, "still-runs")
				return nil
			},
		},
	})

	if err := wd.RunCycle(context.Background()); err == nil {
		t.Fatal("RunCycle() error = nil, want aggregated cycle error")
	}

	expectedOrder := []string{"returns-error", "panics", "still-runs"}
	if !reflect.DeepEqual(executed, expectedOrder) {
		t.Fatalf("check execution order = %v, want %v", executed, expectedOrder)
	}

	status := wd.Status()
	if status.Running {
		t.Fatal("status.Running = true after cycle completion")
	}
	if status.ConsecutiveFailures != 1 {
		t.Fatalf("status.ConsecutiveFailures = %d, want 1", status.ConsecutiveFailures)
	}
	if len(status.Checks) != 3 {
		t.Fatalf("len(status.Checks) = %d, want 3", len(status.Checks))
	}
	if status.Checks[0].OK {
		t.Fatal("first check should be marked failed")
	}
	if !status.Checks[1].Panicked {
		t.Fatal("panic check should be marked as panicked")
	}
	if status.Checks[2].OK != true {
		t.Fatal("third check should still succeed after earlier failures")
	}
	if !strings.Contains(status.Checks[1].Error, `panic in check "panics"`) {
		t.Fatalf("panic error missing details: %q", status.Checks[1].Error)
	}

	breadcrumbRaw, err := os.ReadFile(breadcrumbPath)
	if err != nil {
		t.Fatalf("ReadFile(%q) error = %v", breadcrumbPath, err)
	}
	var persisted Status
	if err := json.Unmarshal(breadcrumbRaw, &persisted); err != nil {
		t.Fatalf("Unmarshal breadcrumb error = %v", err)
	}
	if persisted.Running {
		t.Fatal("persisted breadcrumb indicates running=true after cycle completion")
	}
}

func TestNewRecoversInterruptedBreadcrumb(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	started := time.Now().UTC().Add(-2 * time.Minute)
	previous := Status{
		Hostname:            "test-host",
		PID:                 9999,
		DryRun:              false,
		Running:             true,
		StartedAt:           started.Add(-10 * time.Minute),
		LastCycleStart:      &started,
		ConsecutiveFailures: 3,
		LastError:           "old failure",
	}

	payload, err := json.Marshal(previous)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	if err := os.WriteFile(breadcrumbPath, payload, 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	wd, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	status := wd.Status()
	if !status.RecoveredFromBreadcrumb {
		t.Fatal("RecoveredFromBreadcrumb = false, want true")
	}
	if !status.PreviousCycleInterrupted {
		t.Fatal("PreviousCycleInterrupted = false, want true")
	}
	if status.ConsecutiveFailures != 3 {
		t.Fatalf("ConsecutiveFailures = %d, want 3", status.ConsecutiveFailures)
	}
}

func TestHealthHandlerReturnsJSONStatus(t *testing.T) {
	t.Parallel()

	wd, err := New(Config{
		BreadcrumbPath: filepath.Join(t.TempDir(), "watchdog.json"),
		Logger:         log.New(io.Discard, "", 0),
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	wd.SetChecks([]Check{
		{
			Name: "ok",
			Run: func(ctx context.Context, dryRun bool) error {
				_ = ctx
				_ = dryRun
				return nil
			},
		},
	})
	if err := wd.RunCycle(context.Background()); err != nil {
		t.Fatalf("RunCycle() error = %v, want nil", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()
	wd.HealthHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /health status = %d, want 200", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); !strings.Contains(got, "application/json") {
		t.Fatalf("Content-Type = %q, want application/json", got)
	}

	var resp HealthResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("json.Unmarshal(/health) error = %v", err)
	}
	if resp.Status != "ok" {
		t.Fatalf("health status = %q, want ok", resp.Status)
	}
	if resp.Watchdog.Hostname == "" {
		t.Fatal("hostname is empty in health response")
	}

	nonGetReq := httptest.NewRequest(http.MethodPost, "/health", nil)
	nonGetRec := httptest.NewRecorder()
	wd.HealthHandler(nonGetRec, nonGetReq)
	if nonGetRec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /health status = %d, want 405", nonGetRec.Code)
	}
}
