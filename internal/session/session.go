// Package session defines the agent session lifecycle: agent records,
// session records, state transitions, and the Provider contract that
// plugins implement to run sessions.
package session

import "time"

// SessionState is the lifecycle state of a Session. Valid transitions
// are enforced by Store.TransitionSession:
//
//	created -> started -> running -> stopped
//	created -> stopped (abort before start)
//
// Any other combination is rejected.
type SessionState string

const (
	StateCreated SessionState = "created"
	StateStarted SessionState = "started"
	StateRunning SessionState = "running"
	StateStopped SessionState = "stopped"
)

// Session is a run of an agent under a provider. At most one
// non-stopped Session may exist per agent at a time; this is
// enforced by the sessions_one_active_per_agent partial unique
// index (see internal/db/migrations/001_initial.sql).
type Session struct {
	ID         string
	AgentName  string
	Provider   string
	State      SessionState
	StartedAt  *time.Time
	StoppedAt  *time.Time
	StopReason string
}
