// Package workers invokes the actual Haskell executable and Scala JAR.
package workers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"pocketledger/server/internal/ledger"
)

type Input struct {
	Month             string               `json:"month"`
	AsOf              string               `json:"as_of"`
	MonthlyLimitCents int64                `json:"monthly_limit_cents"`
	Transactions      []ledger.Transaction `json:"transactions"`
}

type Availability struct {
	Haskell bool `json:"haskell"`
	Scala   bool `json:"scala"`
}

type Config struct {
	HaskellWorker  string
	ScalaJAR       string
	Java           string
	Timeout        time.Duration
	MaxOutputBytes int
}

type Engine struct {
	config  Config
	command func(context.Context, string) *exec.Cmd
}

func New(config Config) *Engine {
	if config.Timeout <= 0 {
		config.Timeout = 10 * time.Second
	}
	if config.MaxOutputBytes <= 0 {
		config.MaxOutputBytes = 1 << 20
	}
	if config.Java == "" {
		config.Java = "java"
	}
	e := &Engine{config: config}
	e.command = func(ctx context.Context, name string) *exec.Cmd {
		if name == "haskell" {
			return exec.CommandContext(ctx, config.HaskellWorker)
		}
		return exec.CommandContext(ctx, config.Java, "-jar", config.ScalaJAR)
	}
	return e
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// Availability checks configured files and Java; it does not claim successful calculations.
func (e *Engine) Availability() Availability {
	_, javaErr := exec.LookPath(e.config.Java)
	return Availability{Haskell: fileExists(e.config.HaskellWorker), Scala: fileExists(e.config.ScalaJAR) && javaErr == nil}
}

var errOutputLimit = errors.New("worker output limit exceeded")

type limitedBuffer struct {
	buffer   bytes.Buffer
	limit    int
	overflow bool
	cancel   context.CancelFunc
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	remaining := b.limit - b.buffer.Len()
	if len(p) > remaining {
		b.overflow = true
		b.cancel()
		b.buffer.Write(p[:remaining])
		return remaining, errOutputLimit
	}
	return b.buffer.Write(p)
}

func diagnostic(data []byte) string {
	text := strings.ToValidUTF8(string(data), "?")
	text = strings.Join(strings.Fields(text), " ")
	if len(text) > 512 {
		text = text[:512] + "..."
	}
	return text
}

func (e *Engine) invoke(ctx context.Context, name string, input []byte) ([]byte, error) {
	processCtx, cancel := context.WithTimeout(ctx, e.config.Timeout)
	defer cancel()
	stdout := &limitedBuffer{limit: e.config.MaxOutputBytes, cancel: cancel}
	stderr := &limitedBuffer{limit: 32 << 10, cancel: cancel}
	cmd := e.command(processCtx, name)
	cmd.Stdin = bytes.NewReader(input)
	cmd.Stdout, cmd.Stderr = stdout, stderr
	cmd.WaitDelay = 500 * time.Millisecond
	err := cmd.Run()
	if stdout.overflow || stderr.overflow {
		return nil, fmt.Errorf("%s worker exceeded its output limit", name)
	}
	if processCtx.Err() != nil {
		return nil, fmt.Errorf("%s worker timed out or request was cancelled: %w", name, processCtx.Err())
	}
	if err != nil {
		message := diagnostic(stderr.buffer.Bytes())
		if message != "" {
			return nil, fmt.Errorf("%s worker failed: %w (%s)", name, err, message)
		}
		return nil, fmt.Errorf("%s worker could not run: %w", name, err)
	}
	return stdout.buffer.Bytes(), nil
}

func (e *Engine) Run(ctx context.Context, input Input) (Summary, Analytics, error) {
	payload, err := json.Marshal(input)
	if err != nil {
		return Summary{}, Analytics{}, err
	}
	if len(payload) > 16<<20 {
		return Summary{}, Analytics{}, fmt.Errorf("worker input exceeds 16 MiB; use a smaller reporting month")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	type result struct {
		name   string
		output []byte
		err    error
	}
	results := make(chan result, 2)
	for _, name := range []string{"haskell", "scala"} {
		go func() { output, err := e.invoke(ctx, name, payload); results <- result{name, output, err} }()
	}
	outputs := make(map[string][]byte, 2)
	var failure error
	for range 2 {
		result := <-results
		if result.err != nil && failure == nil {
			failure = result.err
			cancel()
		}
		outputs[result.name] = result.output
	}
	if failure != nil {
		return Summary{}, Analytics{}, failure
	}
	summary, analytics, err := decodeOutputs(input, outputs["haskell"], outputs["scala"])
	if err != nil {
		return Summary{}, Analytics{}, err
	}
	return summary, analytics, nil
}

var _ io.Writer = (*limitedBuffer)(nil)
