package ledger

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func expense(id int) Transaction {
	return Transaction{ID: fmt.Sprintf("b5a5bd60-4cec-4297-af3a-%012d", id), AmountCents: 1250, Category: "food", Note: "Lunch", Date: "2024-02-29"}
}

func TestTransactionValidation(t *testing.T) {
	for _, test := range []struct {
		name   string
		change func(*Transaction)
	}{
		{"uuid", func(x *Transaction) { x.ID = "not-a-uuid" }},
		{"negative", func(x *Transaction) { x.AmountCents = -1 }},
		{"zero", func(x *Transaction) { x.AmountCents = 0 }},
		{"too much", func(x *Transaction) { x.AmountCents = MaxCents + 1 }},
		{"category", func(x *Transaction) { x.Category = "Food" }},
		{"non leap date", func(x *Transaction) { x.Date = "2023-02-29" }},
		{"pre range date", func(x *Transaction) { x.Date = "1999-12-31" }},
		{"non padded date", func(x *Transaction) { x.Date = "2024-2-29" }},
		{"long unicode note", func(x *Transaction) { x.Note = strings.Repeat("🙂", 141) }},
	} {
		t.Run(test.name, func(t *testing.T) {
			x := expense(1)
			test.change(&x)
			if x.Validate() == nil {
				t.Fatal("invalid input accepted")
			}
		})
	}
	x := expense(1)
	x.ID = strings.ToUpper(x.ID)
	x.Note = strings.Repeat("🙂", 140)
	x.AmountCents = MaxCents
	if err := x.Validate(); err != nil {
		t.Fatal(err)
	}
	if x.ID != strings.ToLower(x.ID) {
		t.Fatal("UUID not normalized")
	}
}

func TestPersistenceReplayConflictSnapshotAndDelete(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "ledger.db")
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	first := expense(2)
	created, err := store.Add(ctx, first)
	if err != nil || !created {
		t.Fatalf("create: %v %v", created, err)
	}
	created, err = store.Add(ctx, first)
	if err != nil || created {
		t.Fatalf("replay: %v %v", created, err)
	}
	changed := first
	changed.Note = "Different"
	if _, err := store.Add(ctx, changed); !errors.Is(err, ErrConflict) {
		t.Fatalf("expected conflict, got %v", err)
	}
	second := expense(1)
	_, err = store.Add(ctx, second)
	if err != nil {
		t.Fatal(err)
	}
	prior := expense(3)
	prior.Date = "2024-01-31"
	if _, err = store.Add(ctx, prior); err != nil {
		t.Fatal(err)
	}
	future := expense(4)
	future.Date = "2024-03-01"
	if _, err = store.Add(ctx, future); err != nil {
		t.Fatal(err)
	}
	if _, err = store.SetBudget(ctx, 55555); err != nil {
		t.Fatal(err)
	}
	if err = store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	budget, items, err := store.Snapshot(ctx, "2024-02", "2024-02-29")
	if err != nil || budget.MonthlyLimitCents != 55555 || len(items) != 2 || items[0].ID != second.ID {
		t.Fatalf("snapshot/restart: %+v %+v %v", budget, items, err)
	}
	_, items, err = store.Snapshot(ctx, "2024-02", "2024-02-28")
	if err != nil || len(items) != 0 {
		t.Fatalf("future inclusion: %+v %v", items, err)
	}
	for range 2 {
		if err := store.Delete(ctx, first.ID); err != nil {
			t.Fatal(err)
		}
	}
	items, err = store.List(ctx)
	if err != nil || len(items) != 3 {
		t.Fatalf("delete: %v %v", items, err)
	}
	if items[0].ID != future.ID || items[1].ID != second.ID {
		t.Fatal("descending-date order changed")
	}
}

func TestConcurrentIdenticalCreates(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "ledger.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	var group sync.WaitGroup
	results := make(chan bool, 20)
	failures := make(chan error, 20)
	for range 20 {
		group.Go(func() {
			created, err := store.Add(context.Background(), expense(1))
			results <- created
			failures <- err
		})
	}
	group.Wait()
	close(results)
	close(failures)
	created := 0
	for result := range results {
		if result {
			created++
		}
	}
	for err := range failures {
		if err != nil {
			t.Fatal(err)
		}
	}
	if created != 1 {
		t.Fatalf("wanted one create, got %d", created)
	}
	list, err := store.List(context.Background())
	if err != nil || len(list) != 1 {
		t.Fatalf("duplicate rows: %v %v", list, err)
	}
}
