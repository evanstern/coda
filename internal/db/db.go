// Package db provides SQLite state storage for coda.
//
// Design constraints baked into this package:
//
//   - Pure-Go driver: modernc.org/sqlite. The driver name is "sqlite",
//     not "sqlite3".
//   - Single connection pool (SetMaxOpenConns(1)). SQLite is a
//     single-writer store and a 1-conn pool eliminates write-lock
//     contention at the cost of a hard constraint: callers MUST NOT
//     hold a *sql.Rows cursor (i.e. call rows.Next) while issuing an
//     Exec/ExecContext on the same *sql.DB. That deadlocks. Stream
//     rows into a slice before issuing writes.
//   - Foreign keys and WAL enabled per-connection via DSN pragmas
//     (foreign_keys is per-connection in SQLite).
package db

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

// DefaultPath returns the on-disk location of the coda state DB. It
// honors $XDG_STATE_HOME; otherwise falls back to ~/.local/state.
func DefaultPath() (string, error) {
	base := os.Getenv("XDG_STATE_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve home dir: %w", err)
		}
		base = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(base, "coda", "coda.db"), nil
}

// Open opens (and creates if needed) the SQLite DB at path. The parent
// directory is created with mode 0700 if missing. The returned *sql.DB
// is configured with a single-connection pool; see the package doc
// comment for the implied constraint.
func Open(ctx context.Context, path string) (*sql.DB, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("create state dir: %w", err)
	}
	dsn := path + "?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	db.SetMaxOpenConns(1)
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}
	return db, nil
}
