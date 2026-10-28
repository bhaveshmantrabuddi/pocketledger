package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"time"

	"pocketledger/server/internal/ledger"
	"pocketledger/server/internal/strictjson"
	"pocketledger/server/internal/workers"
)

const MaxRequestBytes = 16 << 10

type Runner interface {
	Run(context.Context, workers.Input) (workers.Summary, workers.Analytics, error)
	Availability() workers.Availability
}

type API struct {
	store  *ledger.Store
	runner Runner
	now    func() time.Time
}

func New(store *ledger.Store, runner Runner) *API {
	return &API{store: store, runner: runner, now: time.Now}
}

func respond(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func failure(w http.ResponseWriter, status int, message string) {
	respond(w, status, map[string]string{"error": message})
}

func method(w http.ResponseWriter, allowed string) {
	w.Header().Set("Allow", allowed)
	failure(w, http.StatusMethodNotAllowed, "method not allowed")
}

func decode(w http.ResponseWriter, r *http.Request, value any, fields ...string) bool {
	if contentType := r.Header.Get("Content-Type"); contentType != "" {
		mediaType, _, err := mime.ParseMediaType(contentType)
		if err != nil || mediaType != "application/json" {
			failure(w, 415, "Content-Type must be application/json")
			return false
		}
	}
	r.Body = http.MaxBytesReader(w, r.Body, MaxRequestBytes)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		var limit *http.MaxBytesError
		if errors.As(err, &limit) {
			failure(w, 413, "request body exceeds 16 KiB")
		} else {
			failure(w, 400, "could not read request body")
		}
		return false
	}
	if err := strictjson.Object(data, value, fields...); err != nil {
		failure(w, 400, err.Error())
		return false
	}
	return true
}

func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", a.health)
	mux.HandleFunc("/v1/transactions", a.transactions)
	mux.HandleFunc("/v1/transactions/{id}", a.deleteTransaction)
	mux.HandleFunc("/v1/budget", a.budget)
	mux.HandleFunc("/v1/dashboard", a.dashboard)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { failure(w, 404, "route not found") })
	return mux
}

func (a *API) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		method(w, "GET")
		return
	}
	if err := a.store.Ping(r.Context()); err != nil {
		failure(w, 503, "SQLite storage unavailable")
		return
	}
	respond(w, 200, struct {
		Status  string               `json:"status"`
		Storage string               `json:"storage"`
		Workers workers.Availability `json:"workers"`
	}{"ok", "sqlite", a.runner.Availability()})
}

func (a *API) transactions(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		items, err := a.store.List(r.Context())
		if err != nil {
			failure(w, 500, "could not read SQLite transactions")
			return
		}
		respond(w, 200, map[string]any{"transactions": items})
	case http.MethodPost:
		var item ledger.Transaction
		if !decode(w, r, &item, "id", "amount_cents", "category", "note", "date") {
			return
		}
		if err := item.Validate(); err != nil {
			failure(w, 400, err.Error())
			return
		}
		created, err := a.store.Add(r.Context(), item)
		if errors.Is(err, ledger.ErrConflict) {
			failure(w, 409, err.Error())
			return
		}
		if err != nil {
			failure(w, 500, "could not save SQLite transaction")
			return
		}
		status := 200
		if created {
			status = 201
			w.Header().Set("Location", "/v1/transactions/"+item.ID)
		}
		respond(w, status, item)
	default:
		method(w, "GET, POST")
	}
}

func (a *API) deleteTransaction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		method(w, "DELETE")
		return
	}
	id, err := ledger.NormalizeID(r.PathValue("id"))
	if err != nil {
		failure(w, 400, err.Error())
		return
	}
	if err := a.store.Delete(r.Context(), id); err != nil {
		failure(w, 500, "could not delete SQLite transaction")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(204)
}

func (a *API) budget(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		budget, err := a.store.Budget(r.Context())
		if err != nil {
			failure(w, 500, "could not read SQLite budget")
			return
		}
		respond(w, 200, budget)
	case http.MethodPut:
		var input struct {
			MonthlyLimitCents int64 `json:"monthly_limit_cents"`
		}
		if !decode(w, r, &input, "monthly_limit_cents") {
			return
		}
		if err := ledger.ValidateCents(input.MonthlyLimitCents); err != nil {
			failure(w, 400, err.Error())
			return
		}
		budget, err := a.store.SetBudget(r.Context(), input.MonthlyLimitCents)
		if err != nil {
			failure(w, 500, "could not save SQLite budget")
			return
		}
		respond(w, 200, budget)
	default:
		method(w, "GET, PUT")
	}
}

func reportingDates(rawQuery string, now time.Time) (string, string, error) {
	query, err := url.ParseQuery(rawQuery)
	if err != nil {
		return "", "", fmt.Errorf("invalid query encoding")
	}
	for name, values := range query {
		if name != "month" && name != "as_of" {
			return "", "", fmt.Errorf("unknown query parameter %q", name)
		}
		if len(values) != 1 || values[0] == "" {
			return "", "", fmt.Errorf("%s must be supplied exactly once and cannot be empty", name)
		}
	}
	month, asOf := query.Get("month"), query.Get("as_of")
	if month == "" {
		month = now.Format("2006-01")
	}
	if asOf == "" {
		asOf = now.Format("2006-01-02")
	}
	parsed, err := time.Parse("2006-01", month)
	if err != nil || len(month) != 7 || parsed.Year() < 2000 || parsed.Year() > 2100 {
		return "", "", fmt.Errorf("month must be valid YYYY-MM in years 2000 through 2100")
	}
	day, err := ledger.ParseDate(asOf)
	if err != nil {
		return "", "", err
	}
	if day.Format("2006-01") != month {
		return "", "", fmt.Errorf("as_of must fall within month; provide both parameters for a historical month")
	}
	return month, asOf, nil
}

func (a *API) dashboard(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		method(w, "GET")
		return
	}
	month, asOf, err := reportingDates(r.URL.RawQuery, a.now())
	if err != nil {
		failure(w, 400, err.Error())
		return
	}
	budget, items, err := a.store.Snapshot(r.Context(), month, asOf)
	if err != nil {
		failure(w, 500, "could not read SQLite reporting snapshot")
		return
	}
	summary, analytics, err := a.runner.Run(r.Context(), workers.Input{Month: month, AsOf: asOf, MonthlyLimitCents: budget.MonthlyLimitCents, Transactions: items})
	if err != nil {
		failure(w, 503, "dashboard workers unavailable: "+err.Error()+". Build the workers and check -haskell-worker, -scala-jar and -java.")
		return
	}
	respond(w, 200, struct {
		Month              string            `json:"month"`
		AsOf               string            `json:"as_of"`
		Currency           string            `json:"currency"`
		MonthlyLimitCents  int64             `json:"monthly_limit_cents"`
		Summary            workers.Summary   `json:"summary"`
		Analytics          workers.Analytics `json:"analytics"`
		CalculationSources map[string]string `json:"calculation_sources"`
	}{month, asOf, "USD", budget.MonthlyLimitCents, summary, analytics, map[string]string{"summary": "haskell", "analytics": "scala"}})
}
