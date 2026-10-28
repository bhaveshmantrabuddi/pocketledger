package ledger

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

var ErrConflict = errors.New("this transaction ID already belongs to different content")

type Store struct{ db *sql.DB }

func Open(path string) (*Store, error) {
	if path != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return nil, fmt.Errorf("create database directory: %w", err)
		}
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	// One connection serializes writers and keeps :memory: databases consistent.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	s := &Store{db: db}
	for _, statement := range []string{
		`PRAGMA busy_timeout=5000`, `PRAGMA journal_mode=WAL`,
		`CREATE TABLE IF NOT EXISTS transactions (
		 id TEXT PRIMARY KEY NOT NULL,
		 amount_cents INTEGER NOT NULL CHECK(amount_cents BETWEEN 1 AND 100000000),
		 category TEXT NOT NULL CHECK(category IN ('food','transport','housing','shopping','health','entertainment','other')),
		 note TEXT NOT NULL CHECK(length(note)<=140), date TEXT NOT NULL)`,
		`CREATE INDEX IF NOT EXISTS transactions_date_id ON transactions(date DESC, id ASC)`,
		`CREATE TABLE IF NOT EXISTS budget (id INTEGER PRIMARY KEY CHECK(id=1), monthly_limit_cents INTEGER NOT NULL CHECK(monthly_limit_cents BETWEEN 1 AND 100000000))`,
		`INSERT INTO budget(id, monthly_limit_cents) VALUES(1,200000) ON CONFLICT(id) DO NOTHING`,
	} {
		if _, err := db.Exec(statement); err != nil {
			db.Close()
			return nil, fmt.Errorf("initialize SQLite: %w", err)
		}
	}
	return s, nil
}

func (s *Store) Close() error                   { return s.db.Close() }
func (s *Store) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }

func (s *Store) Add(ctx context.Context, item Transaction) (bool, error) {
	if err := item.Validate(); err != nil {
		return false, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `INSERT INTO transactions(id,amount_cents,category,note,date) VALUES(?,?,?,?,?) ON CONFLICT(id) DO NOTHING`, item.ID, item.AmountCents, item.Category, item.Note, item.Date)
	if err != nil {
		return false, err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	if count == 0 {
		var existing Transaction
		err := tx.QueryRowContext(ctx, `SELECT id,amount_cents,category,note,date FROM transactions WHERE id=?`, item.ID).Scan(&existing.ID, &existing.AmountCents, &existing.Category, &existing.Note, &existing.Date)
		if err != nil {
			return false, err
		}
		if existing != item {
			return false, ErrConflict
		}
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return count == 1, nil
}

type querier interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}

func readTransactions(ctx context.Context, db querier, query string, args ...any) ([]Transaction, error) {
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]Transaction, 0)
	for rows.Next() {
		var item Transaction
		if err := rows.Scan(&item.ID, &item.AmountCents, &item.Category, &item.Note, &item.Date); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (s *Store) List(ctx context.Context) ([]Transaction, error) {
	return readTransactions(ctx, s.db, `SELECT id,amount_cents,category,note,date FROM transactions ORDER BY date DESC,id ASC`)
}

func (s *Store) Delete(ctx context.Context, id string) error {
	normalized, err := NormalizeID(id)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `DELETE FROM transactions WHERE id=?`, normalized)
	return err
}

func (s *Store) Budget(ctx context.Context) (Budget, error) {
	b := Budget{Currency: "USD"}
	err := s.db.QueryRowContext(ctx, `SELECT monthly_limit_cents FROM budget WHERE id=1`).Scan(&b.MonthlyLimitCents)
	return b, err
}

func (s *Store) SetBudget(ctx context.Context, cents int64) (Budget, error) {
	b := Budget{MonthlyLimitCents: cents, Currency: "USD"}
	if err := ValidateCents(cents); err != nil {
		return Budget{}, err
	}
	_, err := s.db.ExecContext(ctx, `UPDATE budget SET monthly_limit_cents=? WHERE id=1`, cents)
	return b, err
}

// Snapshot reads the budget and eligible transactions in one SQLite transaction.
func (s *Store) Snapshot(ctx context.Context, month, asOf string) (Budget, []Transaction, error) {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return Budget{}, nil, err
	}
	defer tx.Rollback()
	b := Budget{Currency: "USD"}
	if err := tx.QueryRowContext(ctx, `SELECT monthly_limit_cents FROM budget WHERE id=1`).Scan(&b.MonthlyLimitCents); err != nil {
		return Budget{}, nil, err
	}
	items, err := readTransactions(ctx, tx, `SELECT id,amount_cents,category,note,date FROM transactions WHERE date>=? AND date<=? ORDER BY date DESC,id ASC`, month+"-01", asOf)
	if err != nil {
		return Budget{}, nil, err
	}
	if err := tx.Commit(); err != nil {
		return Budget{}, nil, err
	}
	return b, items, nil
}
