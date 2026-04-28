package session

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// ErrNotFound is returned when a lookup matches zero rows.
var ErrNotFound = errors.New("not found")

// ErrInvalidTransition is returned by TransitionSession when the
// requested from->to pair is not a legal step in the state machine.
var ErrInvalidTransition = errors.New("invalid session state transition")

// ErrStaleState is returned by TransitionSession when the caller's
// expected "from" state does not match the row's current state. This
// surfaces concurrent-update races: the SQL update key includes the
// from-state, so zero rows affected == stale caller.
var ErrStaleState = errors.New("stale session state")

// Store is the DB access layer for agents and sessions.
type Store struct {
	db *sql.DB
}

// NewStore wraps the given DB handle. The caller is responsible for
// Open/Close lifecycle.
func NewStore(db *sql.DB) *Store {
	return &Store{db: db}
}

// CreateAgent validates and inserts an agent row. Returns an error on
// name-validation failure or PK conflict.
func (s *Store) CreateAgent(ctx context.Context, a Agent) error {
	if err := ValidateAgentName(a.Name); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO agents(name, provider, config_dir) VALUES (?, ?, ?)`,
		a.Name, a.Provider, a.ConfigDir)
	if err != nil {
		return fmt.Errorf("insert agent: %w", err)
	}
	return nil
}

// GetAgent returns the agent with the given name, or ErrNotFound.
func (s *Store) GetAgent(ctx context.Context, name string) (*Agent, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT name, provider, config_dir, created_at FROM agents WHERE name = ?`, name)
	var a Agent
	var provider, configDir sql.NullString
	var createdAt string
	if err := row.Scan(&a.Name, &provider, &configDir, &createdAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("scan agent: %w", err)
	}
	a.Provider = provider.String
	a.ConfigDir = configDir.String
	ts, err := parseSQLiteTime(createdAt)
	if err != nil {
		return nil, fmt.Errorf("parse created_at: %w", err)
	}
	a.CreatedAt = ts
	return &a, nil
}

// ListAgents returns all agents ordered by creation time.
func (s *Store) ListAgents(ctx context.Context) ([]Agent, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT name, provider, config_dir, created_at FROM agents ORDER BY created_at, name`)
	if err != nil {
		return nil, fmt.Errorf("query agents: %w", err)
	}
	defer rows.Close()
	var out []Agent
	for rows.Next() {
		var a Agent
		var provider, configDir sql.NullString
		var createdAt string
		if err := rows.Scan(&a.Name, &provider, &configDir, &createdAt); err != nil {
			return nil, fmt.Errorf("scan agent: %w", err)
		}
		a.Provider = provider.String
		a.ConfigDir = configDir.String
		ts, err := parseSQLiteTime(createdAt)
		if err != nil {
			return nil, fmt.Errorf("parse created_at: %w", err)
		}
		a.CreatedAt = ts
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// CreateSession inserts a session row. The caller is expected to have
// already generated a ULID ID (see NewSessionID). Fails with a UNIQUE
// constraint error if another non-stopped session exists for the same
// agent (enforced by the sessions_one_active_per_agent partial index).
//
// ProviderSessionID is typically empty at create time; populate it
// after Provider.Start returns via SetProviderSessionID.
func (s *Store) CreateSession(ctx context.Context, sess Session) error {
	if sess.State == "" {
		sess.State = StateCreated
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO sessions(id, agent_name, provider, provider_session_id, state)
		 VALUES (?, ?, ?, ?, ?)`,
		sess.ID, sess.AgentName, sess.Provider, sess.ProviderSessionID, string(sess.State))
	if err != nil {
		return fmt.Errorf("insert session: %w", err)
	}
	return nil
}

// SetProviderSessionID records the provider's native session ID on
// an existing session row. Called after Provider.Start returns. The
// row must exist; ErrNotFound is returned otherwise.
//
// SQLite reports RowsAffected==0 for a no-op UPDATE (setting the
// column to its existing value), so we can't use that as the
// existence signal. Verify directly with a follow-up SELECT when
// the UPDATE reports zero rows changed.
func (s *Store) SetProviderSessionID(ctx context.Context, codaSessionID, providerSessionID string) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE sessions SET provider_session_id = ? WHERE id = ?`,
		providerSessionID, codaSessionID)
	if err != nil {
		return fmt.Errorf("set provider_session_id: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("rows affected: %w", err)
	}
	if n == 0 {
		var exists int
		if err := s.db.QueryRowContext(ctx, `SELECT 1 FROM sessions WHERE id = ?`, codaSessionID).Scan(&exists); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("verify session existence: %w", err)
		}
	}
	return nil
}

// GetSession returns the session with the given ID, or ErrNotFound.
func (s *Store) GetSession(ctx context.Context, id string) (*Session, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT id, agent_name, provider, provider_session_id, state, started_at, stopped_at, stop_reason
		   FROM sessions WHERE id = ?`, id)
	return scanSession(row)
}

// GetActiveSession returns the non-stopped session for the given
// agent, if any. Returns ErrNotFound if none.
func (s *Store) GetActiveSession(ctx context.Context, agentName string) (*Session, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT id, agent_name, provider, provider_session_id, state, started_at, stopped_at, stop_reason
		   FROM sessions WHERE agent_name = ? AND state != 'stopped'
		   LIMIT 1`, agentName)
	return scanSession(row)
}

// ListSessionsForAgent returns all sessions for an agent, oldest first.
func (s *Store) ListSessionsForAgent(ctx context.Context, agentName string) ([]Session, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, agent_name, provider, provider_session_id, state, started_at, stopped_at, stop_reason
		   FROM sessions WHERE agent_name = ? ORDER BY id`, agentName)
	if err != nil {
		return nil, fmt.Errorf("query sessions: %w", err)
	}
	defer rows.Close()
	var out []Session
	for rows.Next() {
		var (
			sess                             Session
			startedAt, stoppedAt, stopReason sql.NullString
			state                            string
		)
		if err := rows.Scan(&sess.ID, &sess.AgentName, &sess.Provider, &sess.ProviderSessionID, &state,
			&startedAt, &stoppedAt, &stopReason); err != nil {
			return nil, fmt.Errorf("scan session: %w", err)
		}
		sess.State = SessionState(state)
		if startedAt.Valid {
			ts, err := parseSQLiteTime(startedAt.String)
			if err != nil {
				return nil, err
			}
			sess.StartedAt = &ts
		}
		if stoppedAt.Valid {
			ts, err := parseSQLiteTime(stoppedAt.String)
			if err != nil {
				return nil, err
			}
			sess.StoppedAt = &ts
		}
		sess.StopReason = stopReason.String
		out = append(out, sess)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// TransitionSession atomically moves a session from one state to
// another using a single UPDATE keyed on both id and current state.
// The SQL itself enforces the "from" precondition -- if zero rows
// are affected, the caller had stale state. Invalid pairs (e.g.
// running -> created, stopped -> anything) return ErrInvalidTransition
// without touching the DB.
//
// Side effects:
//   - transition to StateStarted sets started_at = datetime('now')
//   - transition to StateStopped sets stopped_at = datetime('now')
//     and records stop_reason (variadic; first value wins)
func (s *Store) TransitionSession(ctx context.Context, id string, from, to SessionState, stopReason ...string) error {
	if !validTransition(from, to) {
		return fmt.Errorf("%w: %s -> %s", ErrInvalidTransition, from, to)
	}
	var (
		query string
		args  []any
	)
	switch to {
	case StateStarted:
		query = `UPDATE sessions
		           SET state = ?, started_at = datetime('now')
		         WHERE id = ? AND state = ?`
		args = []any{string(to), id, string(from)}
	case StateStopped:
		reason := ""
		if len(stopReason) > 0 {
			reason = stopReason[0]
		}
		query = `UPDATE sessions
		           SET state = ?, stopped_at = datetime('now'), stop_reason = ?
		         WHERE id = ? AND state = ?`
		args = []any{string(to), reason, id, string(from)}
	default:
		query = `UPDATE sessions SET state = ? WHERE id = ? AND state = ?`
		args = []any{string(to), id, string(from)}
	}
	res, err := s.db.ExecContext(ctx, query, args...)
	if err != nil {
		return fmt.Errorf("transition session: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("rows affected: %w", err)
	}
	if n == 0 {
		return fmt.Errorf("%w: session %s not in state %s", ErrStaleState, id, from)
	}
	return nil
}

// RollbackFromStopped reverts a stopped session back to a prior
// non-terminal state. This is only for the narrow case where a
// higher layer optimistically transitioned to stopped but the
// corresponding external action (e.g. Provider.Stop()) failed.
// The caller is responsible for knowing that the rollback makes
// sense. `to` must be one of: created, started, running.
//
// The rollback also clears stopped_at and stop_reason that the
// forward transition set, so the row's termination metadata stays
// consistent with its state.
func (s *Store) RollbackFromStopped(ctx context.Context, id string, to SessionState) error {
	switch to {
	case StateCreated, StateStarted, StateRunning:
	default:
		return fmt.Errorf("%w: rollback to %s", ErrInvalidTransition, to)
	}
	res, err := s.db.ExecContext(ctx,
		`UPDATE sessions
		    SET state = ?, stopped_at = NULL, stop_reason = ''
		  WHERE id = ? AND state = 'stopped'`,
		string(to), id)
	if err != nil {
		return fmt.Errorf("rollback from stopped: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("rows affected: %w", err)
	}
	if n == 0 {
		return fmt.Errorf("%w: session %s not in state stopped", ErrStaleState, id)
	}
	return nil
}

func validTransition(from, to SessionState) bool {
	switch from {
	case StateCreated:
		return to == StateStarted || to == StateStopped
	case StateStarted:
		return to == StateRunning || to == StateStopped
	case StateRunning:
		return to == StateStopped
	case StateStopped:
		return false
	}
	return false
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanSession(row rowScanner) (*Session, error) {
	var (
		sess                             Session
		startedAt, stoppedAt, stopReason sql.NullString
		state                            string
	)
	err := row.Scan(&sess.ID, &sess.AgentName, &sess.Provider, &sess.ProviderSessionID, &state,
		&startedAt, &stoppedAt, &stopReason)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("scan session: %w", err)
	}
	sess.State = SessionState(state)
	if startedAt.Valid {
		ts, err := parseSQLiteTime(startedAt.String)
		if err != nil {
			return nil, err
		}
		sess.StartedAt = &ts
	}
	if stoppedAt.Valid {
		ts, err := parseSQLiteTime(stoppedAt.String)
		if err != nil {
			return nil, err
		}
		sess.StoppedAt = &ts
	}
	sess.StopReason = stopReason.String
	return &sess, nil
}

// parseSQLiteTime parses SQLite's datetime('now') output. The string
// has no timezone suffix; SQLite stores UTC, so we parse as UTC.
func parseSQLiteTime(s string) (time.Time, error) {
	return time.ParseInLocation("2006-01-02 15:04:05", s, time.UTC)
}
