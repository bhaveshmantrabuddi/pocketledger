package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"pocketledger/server/internal/ledger"
	"pocketledger/server/internal/workers"
)

const validExpense = `{"id":"b5a5bd60-4cec-4297-af3a-c980b7c3b97b","amount_cents":1250,"category":"food","note":"Lunch","date":"2024-02-29"}`

type runnerStub struct {
	input workers.Input
	err   error
	calls int
}

func (r *runnerStub) Availability() workers.Availability {
	return workers.Availability{Haskell: true, Scala: true}
}
func (r *runnerStub) Run(_ context.Context, input workers.Input) (workers.Summary, workers.Analytics, error) {
	r.input = input
	r.calls++
	return workers.Summary{}, workers.Analytics{}, r.err
}

func setup(t *testing.T) (*API, http.Handler, *runnerStub) {
	t.Helper()
	store, err := ledger.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	runner := &runnerStub{}
	a := New(store, runner)
	a.now = func() time.Time { return time.Date(2024, 2, 29, 17, 0, 0, 0, time.FixedZone("local", -4*3600)) }
	return a, a.Handler(), runner
}

func request(handler http.Handler, method, path, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func TestAPIReplayConflictDeleteAndBudget(t *testing.T) {
	_, handler, _ := setup(t)
	for i, want := range []int{201, 200} {
		w := request(handler, "POST", "/v1/transactions", validExpense)
		if w.Code != want {
			t.Fatalf("post %d: %d %s", i, w.Code, w.Body)
		}
	}
	w := request(handler, "POST", "/v1/transactions", strings.Replace(validExpense, "Lunch", "Dinner", 1))
	if w.Code != 409 {
		t.Fatalf("conflict: %d %s", w.Code, w.Body)
	}
	w = request(handler, "GET", "/v1/transactions", "")
	var list struct {
		Transactions []ledger.Transaction `json:"transactions"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &list); err != nil || len(list.Transactions) != 1 {
		t.Fatalf("list: %s %v", w.Body, err)
	}
	for range 2 {
		if w := request(handler, "DELETE", "/v1/transactions/b5a5bd60-4cec-4297-af3a-c980b7c3b97b", ""); w.Code != 204 || w.Body.Len() != 0 {
			t.Fatalf("delete: %d %s", w.Code, w.Body)
		}
	}
	for index, method := range []string{"GET", "PUT", "GET"} {
		body := ""
		want := int64(200000)
		if index > 0 {
			want = 12345
		}
		if method == "PUT" {
			body = `{"monthly_limit_cents":12345}`
			want = 12345
		}
		w := request(handler, method, "/v1/budget", body)
		var budget ledger.Budget
		if err := json.Unmarshal(w.Body.Bytes(), &budget); err != nil || w.Code != 200 || budget.Currency != "USD" {
			t.Fatalf("budget: %d %s %v", w.Code, w.Body, err)
		}
		if budget.MonthlyLimitCents != want {
			t.Fatal("budget not updated")
		}
	}
}

func TestValidationRejectsMalformedAmbiguousAndOversizeJSON(t *testing.T) {
	_, handler, _ := setup(t)
	cases := []struct {
		name, body string
		status     int
	}{
		{"empty", "", 400}, {"null", "null", 400}, {"array", "[]", 400},
		{"unknown", strings.Replace(validExpense, `"note":"Lunch"`, `"note":"Lunch","extra":1`, 1), 400},
		{"duplicate", strings.Replace(validExpense, `"amount_cents":1250`, `"amount_cents":1250,"amount_cents":2000`, 1), 400},
		{"trailing", validExpense + " {}", 400}, {"fraction", strings.Replace(validExpense, "1250", "1250.1", 1), 400},
		{"exponent", strings.Replace(validExpense, "1250", "1e3", 1), 400},
		{"overflow", strings.Replace(validExpense, "1250", "9223372036854775808", 1), 400},
		{"invalid UUID", strings.Replace(validExpense, "b5a5bd60-4cec-4297-af3a-c980b7c3b97b", "bad", 1), 400},
		{"invalid date", strings.Replace(validExpense, "2024-02-29", "2023-02-29", 1), 400},
		{"zero", strings.Replace(validExpense, "1250", "0", 1), 400},
		{"null note", strings.Replace(validExpense, `"Lunch"`, `null`, 1), 400},
		{"missing note", strings.Replace(validExpense, `"note":"Lunch",`, "", 1), 400},
		{"unicode length", strings.Replace(validExpense, "Lunch", strings.Repeat("🙂", 141), 1), 400},
		{"invalid UTF-8", strings.Replace(validExpense, "Lunch", string([]byte{0xff}), 1), 400},
		{"size", strings.Replace(validExpense, "Lunch", strings.Repeat("a", MaxRequestBytes), 1), 413},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			w := request(handler, "POST", "/v1/transactions", test.body)
			var result map[string]string
			err := json.Unmarshal(w.Body.Bytes(), &result)
			if w.Code != test.status || err != nil || result["error"] == "" {
				t.Fatalf("%d %s %v", w.Code, w.Body, err)
			}
		})
	}
	for _, body := range []string{`{"monthly_limit_cents":0}`, `{"monthly_limit_cents":100000001}`, `{"monthly_limit_cents":12.5}`, `{"monthly_limit_cents":1,"currency":"USD"}`} {
		if w := request(handler, "PUT", "/v1/budget", body); w.Code != 400 {
			t.Fatalf("bad budget accepted: %s", body)
		}
	}
	w := request(handler, "GET", "/missing", "")
	if w.Code != 404 || !strings.Contains(w.Body.String(), `"error"`) {
		t.Fatal("404 not JSON")
	}
	w = request(handler, "PATCH", "/v1/budget", "")
	if w.Code != 405 || w.Header().Get("Allow") == "" {
		t.Fatal("method error")
	}
	w = request(handler, "DELETE", "/v1/transactions/bad", "")
	if w.Code != 400 {
		t.Fatal("invalid delete id accepted")
	}
}

func TestDashboardSnapshotDefaultsAndUnavailableWorkers(t *testing.T) {
	a, handler, runner := setup(t)
	if w := request(handler, "POST", "/v1/transactions", validExpense); w.Code != 201 {
		t.Fatal(w.Body)
	}
	future := strings.Replace(strings.Replace(validExpense, "b5a5bd60", "b5a5bd61", 1), "2024-02-29", "2024-03-01", 1)
	if w := request(handler, "POST", "/v1/transactions", future); w.Code != 201 {
		t.Fatal(w.Body)
	}
	w := request(handler, "GET", "/v1/dashboard", "")
	if w.Code != 200 || runner.input.Month != "2024-02" || runner.input.AsOf != "2024-02-29" || len(runner.input.Transactions) != 1 {
		t.Fatalf("snapshot: %d %+v", w.Code, runner.input)
	}
	if !strings.Contains(w.Body.String(), `"summary":"haskell"`) {
		t.Fatal("missing provenance")
	}
	w = request(handler, "GET", "/v1/dashboard?month=2024-02&as_of=2024-02-28", "")
	if w.Code != 200 || len(runner.input.Transactions) != 0 {
		t.Fatal("future expense included")
	}
	for _, query := range []string{"month=2024-2", "month=2024-01", "as_of=2023-02-29", "month=2024-02&as_of=2024-03-01", "month=2024-02&month=2024-02", "extra=1", "month=", "month=%zz"} {
		before := runner.calls
		w = request(handler, "GET", "/v1/dashboard?"+query, "")
		if w.Code != 400 || runner.calls != before {
			t.Fatalf("invalid query %s: %d %s", query, w.Code, w.Body)
		}
	}
	runner.err = errors.New("scala worker could not run")
	w = request(handler, "GET", "/v1/dashboard", "")
	if w.Code != 503 || !strings.Contains(w.Body.String(), "Build the workers") {
		t.Fatalf("worker failure: %d %s", w.Code, w.Body)
	}
	// Worker failure leaves persisted ledger and budget usable.
	list, err := a.store.List(context.Background())
	if err != nil || len(list) != 2 {
		t.Fatal("worker failure modified ledger")
	}
	w = request(handler, "GET", "/health", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"storage":"sqlite"`) {
		t.Fatal(w.Body)
	}
}
