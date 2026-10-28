package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"
	"time"

	"pocketledger/server/internal/api"
	"pocketledger/server/internal/ledger"
	"pocketledger/server/internal/workers"
)

func findRoot(start string) string {
	for candidate := start; ; candidate = filepath.Dir(candidate) {
		if info, err := os.Stat(filepath.Join(candidate, "CONTRACT.md")); err == nil && !info.IsDir() {
			return candidate
		}
		if filepath.Dir(candidate) == candidate {
			break
		}
	}
	return ""
}

func repositoryRoot() string {
	cwd, err := os.Getwd()
	if err != nil {
		return "."
	}
	if root := findRoot(cwd); root != "" {
		return root
	}
	if executable, err := os.Executable(); err == nil {
		if root := findRoot(filepath.Dir(executable)); root != "" {
			return root
		}
	}
	return cwd
}

func run() error {
	root := repositoryRoot()
	workerName := "budget-engine"
	if runtime.GOOS == "windows" {
		workerName += ".exe"
	}
	listen := flag.String("listen", "127.0.0.1:8080", "HTTP listen address (single local ledger; no authentication)")
	dbPath := flag.String("db", filepath.Join(root, ".local", "data", "ledger.db"), "SQLite database file")
	haskell := flag.String("haskell-worker", filepath.Join(root, ".local", "workers", workerName), "Haskell budget-engine executable")
	scala := flag.String("scala-jar", filepath.Join(root, ".local", "workers", "analytics.jar"), "Scala executable fat JAR")
	java := flag.String("java", "java", "Java executable, or a name resolved on PATH")
	workerTimeout := flag.Duration("worker-timeout", 10*time.Second, "timeout for each dashboard worker")
	flag.Parse()
	if *workerTimeout <= 0 {
		return fmt.Errorf("-worker-timeout must be positive")
	}
	store, err := ledger.Open(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	engine := workers.New(workers.Config{HaskellWorker: *haskell, ScalaJAR: *scala, Java: *java, Timeout: *workerTimeout})
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	server := &http.Server{Addr: *listen, Handler: api.New(store, engine).Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: *workerTimeout + 5*time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	done := make(chan error, 1)
	go func() { done <- server.ListenAndServe() }()
	log.Printf("PocketLedger local API on %s; SQLite: %s", *listen, *dbPath)
	select {
	case err := <-done:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			_ = server.Close()
			return err
		}
		if err := <-done; !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
