package workers

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pocketledger/server/internal/ledger"
)

var sampleTransaction = ledger.Transaction{ID: "b5a5bd60-4cec-4297-af3a-c980b7c3b97b", AmountCents: 125, Category: "food", Note: "Test", Date: "2024-02-01"}

func sampleInput() Input {
	return Input{Month: "2024-02", AsOf: "2024-02-02", MonthlyLimitCents: 100, Transactions: []ledger.Transaction{sampleTransaction}}
}
func sampleSummary() Summary {
	return Summary{SpentCents: 125, RemainingCents: -25, ElapsedDays: 2, DaysInMonth: 29, DaysRemaining: 27, ProjectedCents: 1813, DailyAllowanceCents: 0, Status: "over_budget"}
}
func sampleAnalytics() Analytics {
	return Analytics{Categories: []Category{{Category: "food", SpentCents: 125, Count: 1}}, Daily: []Daily{{Date: "2024-02-01", SpentCents: 125}, {Date: "2024-02-02", SpentCents: 0}}, Largest: []ledger.Transaction{sampleTransaction}}
}

// This child process fixture tests OS process execution without requiring a
// language toolchain. Production Engine always launches the Haskell binary/JAR.
func TestWorkerHelperProcess(t *testing.T) {
	if os.Getenv("POCKETLEDGER_TEST_WORKER") != "1" {
		return
	}
	mode := os.Args[len(os.Args)-1]
	var input Input
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		fmt.Fprintln(os.Stderr, "invalid worker stdin")
		os.Exit(2)
	}
	if input.Month != "2024-02" || input.MonthlyLimitCents != 100 || len(input.Transactions) != 1 {
		fmt.Fprintln(os.Stderr, "unexpected worker stdin")
		os.Exit(2)
	}
	switch mode {
	case "summary":
		_ = json.NewEncoder(os.Stdout).Encode(sampleSummary())
	case "analytics":
		_ = json.NewEncoder(os.Stdout).Encode(sampleAnalytics())
	case "bad-json":
		fmt.Fprint(os.Stdout, "debug log, not JSON")
	case "trailing":
		_ = json.NewEncoder(os.Stdout).Encode(sampleSummary())
		fmt.Fprint(os.Stdout, "{}")
	case "bad-total":
		s := sampleSummary()
		s.SpentCents = 0
		_ = json.NewEncoder(os.Stdout).Encode(s)
	case "fail":
		fmt.Fprintln(os.Stderr, "fixture calculation failed")
		os.Exit(3)
	case "timeout":
		time.Sleep(30 * time.Second)
	case "huge-stdout":
		_, _ = io.WriteString(os.Stdout, strings.Repeat("x", 100000))
	case "huge-stderr":
		_, _ = io.WriteString(os.Stderr, strings.Repeat("x", 100000))
	default:
		os.Exit(4)
	}
	os.Exit(0)
}

func helperEngine(summaryMode, analyticsMode string) *Engine {
	e := New(Config{Timeout: 3 * time.Second, MaxOutputBytes: 1024})
	e.command = func(ctx context.Context, name string) *exec.Cmd {
		mode := summaryMode
		if name == "scala" {
			mode = analyticsMode
		}
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestWorkerHelperProcess$", "--", mode)
		cmd.Env = append(os.Environ(), "POCKETLEDGER_TEST_WORKER=1")
		return cmd
	}
	return e
}

func TestRealSubprocessRoundTrip(t *testing.T) {
	summary, analytics, err := helperEngine("summary", "analytics").Run(context.Background(), sampleInput())
	if err != nil {
		t.Fatal(err)
	}
	if summary.Status != "over_budget" || summary.DaysInMonth != 29 || summary.RemainingCents != -25 || len(analytics.Daily) != 2 {
		t.Fatalf("bad subprocess output: %+v %+v", summary, analytics)
	}
}

func TestWorkerFailuresNeverReturnFallbackAnalytics(t *testing.T) {
	for _, test := range []struct{ mode, contains string }{
		{"bad-json", "invalid Haskell output"}, {"trailing", "exactly one JSON"},
		{"bad-total", "inconsistent"}, {"fail", "fixture calculation failed"},
		{"timeout", "timed out"}, {"huge-stdout", "output limit"}, {"huge-stderr", "output limit"},
	} {
		t.Run(test.mode, func(t *testing.T) {
			e := helperEngine(test.mode, "analytics")
			if test.mode == "timeout" {
				e.config.Timeout = 200 * time.Millisecond
			}
			summary, analytics, err := e.Run(context.Background(), sampleInput())
			if err == nil || !strings.Contains(err.Error(), test.contains) {
				t.Fatalf("wanted %q error, got %v", test.contains, err)
			}
			if summary.Status != "" || analytics.Daily != nil {
				t.Fatal("partial/fallback analytics returned")
			}
		})
	}
	t.Run("scala failure", func(t *testing.T) {
		_, _, err := helperEngine("summary", "fail").Run(context.Background(), sampleInput())
		if err == nil || !strings.Contains(err.Error(), "scala") {
			t.Fatalf("%v", err)
		}
	})
	t.Run("cancelled request", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		_, _, err := helperEngine("timeout", "timeout").Run(ctx, sampleInput())
		if err == nil {
			t.Fatal("cancelled request ran")
		}
	})
	t.Run("missing binary", func(t *testing.T) {
		e := New(Config{HaskellWorker: filepath.Join(t.TempDir(), "missing"), Java: "missing-pocketledger-java", ScalaJAR: "missing.jar"})
		_, _, err := e.Run(context.Background(), sampleInput())
		if err == nil {
			t.Fatal("missing binary accepted")
		}
		if e.Availability() != (Availability{}) {
			t.Fatal("missing workers marked ready")
		}
	})
}

func TestProtocolRejectsMalformedAnalytics(t *testing.T) {
	summaryJSON, _ := json.Marshal(sampleSummary())
	for _, mutate := range []func(*Analytics){
		func(a *Analytics) { a.Daily = a.Daily[:1] },
		func(a *Analytics) { a.Categories[0].Count = 2 },
		func(a *Analytics) { a.Daily[1].SpentCents = 1 },
		func(a *Analytics) { a.Largest[0].Note = "changed" },
		func(a *Analytics) { a.Categories = nil },
	} {
		a := sampleAnalytics()
		mutate(&a)
		payload, _ := json.Marshal(a)
		if _, _, err := decodeOutputs(sampleInput(), summaryJSON, payload); err == nil {
			t.Fatalf("invalid analytics accepted: %s", payload)
		}
	}
}
