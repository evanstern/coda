package db_test

import (
	"context"
	"database/sql"
	"testing"

	"github.com/evanstern/coda/internal/db"
	_ "modernc.org/sqlite"
)

func openTestDB(t *testing.T) *sql.DB {
	t.Helper()
	d, err := sql.Open("sqlite", "file::memory:?cache=shared&_pragma=foreign_keys(1)")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	d.SetMaxOpenConns(1)
	t.Cleanup(func() { d.Close() })
	return d
}

func TestMigrateIdempotent(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("first migrate: %v", err)
	}
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("second migrate: %v", err)
	}
	var count int
	if err := d.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations`).Scan(&count); err != nil {
		t.Fatalf("count schema_migrations: %v", err)
	}
	if count != 4 {
		t.Fatalf("expected 4 applied migrations, got %d", count)
	}

	tables := map[string]bool{}
	rows, err := d.QueryContext(ctx, `SELECT name FROM sqlite_master WHERE type='table'`)
	if err != nil {
		t.Fatalf("list tables: %v", err)
	}
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			t.Fatalf("scan: %v", err)
		}
		tables[n] = true
	}
	rows.Close()
	for _, want := range []string{"agents", "sessions", "messages", "schema_migrations"} {
		if !tables[want] {
			t.Errorf("expected table %q to exist", want)
		}
	}
}
