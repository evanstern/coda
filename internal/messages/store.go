package messages

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/evanstern/coda/internal/session"
)

// Store is the DB access layer for messages. Mirrors session.Store style.
type Store struct {
	db *sql.DB
}

// NewStore wraps the given DB handle. The caller is responsible for
// Open/Close lifecycle.
func NewStore(db *sql.DB) *Store {
	return &Store{db: db}
}

// Insert persists a new message. Returns the assigned ID.
func (s *Store) Insert(ctx context.Context, sender, recipient string, t MessageType, body []byte) (int64, error) {
	if err := ValidateType(t); err != nil {
		return 0, err
	}
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO messages(sender, recipient, type, body) VALUES (?, ?, ?, ?)`,
		sender, recipient, string(t), string(body))
	if err != nil {
		return 0, fmt.Errorf("insert message: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("last insert id: %w", err)
	}
	return id, nil
}

// MarkDelivered sets delivered_at to now() for the given id.
func (s *Store) MarkDelivered(ctx context.Context, id int64) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE messages SET delivered_at = datetime('now') WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("mark delivered: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("rows affected: %w", err)
	}
	if n == 0 {
		return session.ErrNotFound
	}
	return nil
}

// MarkAcked sets acked_at to now() for the given id.
func (s *Store) MarkAcked(ctx context.Context, id int64) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE messages SET acked_at = datetime('now') WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("mark acked: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("rows affected: %w", err)
	}
	if n == 0 {
		return session.ErrNotFound
	}
	return nil
}

// ListUnacked returns all unacked messages for recipient, oldest first.
func (s *Store) ListUnacked(ctx context.Context, recipient string) ([]Stored, error) {
	return s.listWhere(ctx,
		`SELECT id, sender, recipient, type, body, created_at, delivered_at, acked_at
		   FROM messages WHERE recipient = ? AND acked_at IS NULL
		   ORDER BY id`, recipient)
}

// ListUndelivered returns all undelivered, unacked messages for
// recipient, oldest first. Used by drain-on-start. Acked messages
// are skipped even if they were never delivered, so a manually
// acked row does not get re-routed.
func (s *Store) ListUndelivered(ctx context.Context, recipient string) ([]Stored, error) {
	return s.listWhere(ctx,
		`SELECT id, sender, recipient, type, body, created_at, delivered_at, acked_at
		   FROM messages WHERE recipient = ? AND delivered_at IS NULL AND acked_at IS NULL
		   ORDER BY id`, recipient)
}

func (s *Store) listWhere(ctx context.Context, query string, args ...any) ([]Stored, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("query messages: %w", err)
	}
	defer rows.Close()
	var out []Stored
	for rows.Next() {
		m, err := scanStored(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// Get returns one message by id, or session.ErrNotFound.
func (s *Store) Get(ctx context.Context, id int64) (*Stored, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT id, sender, recipient, type, body, created_at, delivered_at, acked_at
		   FROM messages WHERE id = ?`, id)
	m, err := scanStoredRow(row)
	if err != nil {
		return nil, err
	}
	return &m, nil
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanStoredRow(row rowScanner) (Stored, error) {
	m, err := scanStoredFields(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Stored{}, session.ErrNotFound
		}
		return Stored{}, err
	}
	return m, nil
}

func scanStored(row rowScanner) (Stored, error) {
	return scanStoredFields(row)
}

func scanStoredFields(row rowScanner) (Stored, error) {
	var (
		m                        Stored
		typeStr, body, createdAt string
		deliveredAt, ackedAt     sql.NullString
	)
	if err := row.Scan(&m.ID, &m.Sender, &m.Recipient, &typeStr, &body, &createdAt, &deliveredAt, &ackedAt); err != nil {
		return Stored{}, fmt.Errorf("scan message: %w", err)
	}
	m.Type = MessageType(typeStr)
	m.Body = []byte(body)
	ts, err := parseSQLiteTime(createdAt)
	if err != nil {
		return Stored{}, fmt.Errorf("parse created_at: %w", err)
	}
	m.CreatedAt = ts
	if deliveredAt.Valid {
		ts, err := parseSQLiteTime(deliveredAt.String)
		if err != nil {
			return Stored{}, fmt.Errorf("parse delivered_at: %w", err)
		}
		m.DeliveredAt = &ts
	}
	if ackedAt.Valid {
		ts, err := parseSQLiteTime(ackedAt.String)
		if err != nil {
			return Stored{}, fmt.Errorf("parse acked_at: %w", err)
		}
		m.AckedAt = &ts
	}
	return m, nil
}

// parseSQLiteTime parses SQLite's datetime('now') output (UTC, no tz).
func parseSQLiteTime(s string) (time.Time, error) {
	return time.ParseInLocation("2006-01-02 15:04:05", s, time.UTC)
}
