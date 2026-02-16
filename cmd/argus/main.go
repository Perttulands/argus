package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/perttu/argus/internal/watchdog"
)

func main() {
	var (
		breadcrumbPath = flag.String("breadcrumb-file", "logs/watchdog.breadcrumb.json", "breadcrumb state file path")
		healthAddr     = flag.String("health-addr", ":8080", "health server bind address (empty disables server)")
		interval       = flag.Duration("interval", 5*time.Minute, "watchdog interval")
		once           = flag.Bool("once", false, "run one cycle and exit")
		dryRun         = flag.Bool("dry-run", false, "log intended actions without executing them")
	)
	flag.Parse()

	logger := log.New(os.Stdout, "argus: ", log.LstdFlags|log.LUTC)

	wd, err := watchdog.New(watchdog.Config{
		BreadcrumbPath: *breadcrumbPath,
		Logger:         logger,
		DryRun:         *dryRun,
	})
	if err != nil {
		logger.Fatalf("watchdog init failed: %v", err)
	}

	wd.SetChecks([]watchdog.Check{
		{
			Name: "collect-metrics",
			Run: func(ctx context.Context, dryRun bool) error {
				_ = ctx
				if dryRun {
					logger.Printf("dry-run: would collect metrics and evaluate actions")
				}
				return nil
			},
		},
		{
			Name: "execute-actions",
			Run: func(ctx context.Context, dryRun bool) error {
				_ = ctx
				if dryRun {
					logger.Printf("dry-run: action execution skipped")
					return nil
				}
				// Action execution hook for production integrations.
				return nil
			},
		},
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var srv *http.Server
	if *healthAddr != "" {
		mux := http.NewServeMux()
		mux.HandleFunc("/health", wd.HealthHandler)
		srv = &http.Server{
			Addr:              *healthAddr,
			Handler:           mux,
			ReadHeaderTimeout: 2 * time.Second,
		}
		go func() {
			logger.Printf("health endpoint listening on %s", *healthAddr)
			if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				logger.Printf("health server stopped with error: %v", err)
			}
		}()
	}

	wd.Run(ctx, *interval, *once)

	if srv != nil {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			logger.Printf("health server shutdown failed: %v", err)
		}
	}
}
