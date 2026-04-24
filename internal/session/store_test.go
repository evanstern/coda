package session_test

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"

	"github.com/evanstern/coda/internal/db"
	"github.com/evanstern/coda/internal/session"
	_ "modernc.org/sqlite"
)

func newStore(t *testing.T) (*session.Store, *sql.DB) {
	t.Helper()
	d, err := sql.Open("sqlite", "file::memory:?cache=shared&_pragma=foreign_keys(1)")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	d.SetMaxOpenConns(1)
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return session.NewStore(d), d
}

func TestCreateAgentValidation(t *testing.T) {
	store, _ := newStore(t)
	ctx := context.Background()
	cases := []struct {
		name   string
		agent  string
		wantOK bool
	}{
		{"empty", "", false},
		{"bad char", "has space", false},
		{"underscore", "a_b", false},
		{"too long", strings.Repeat("a", 65), false},
		{"max len", strings.Repeat("a", 64), true},
		{"ok", "ok-agent-1", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := store.CreateAgent(ctx, session.Agent{Name: c.agent})
			if c.wantOK && err != nil {
				t.Fatalf("expected ok, got %v", err)
			}
			if !c.wantOK && err == nil {
				t.Fatalf("expected error for %q", c.agent)
			}
		})
	}
}

func TestCreateAgentDuplicate(t *testing.T) {
	store, _ := newStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a"}); err != nil {
		t.Fatal(err)
	}
	if err := store.CreateAgent(ctx, session.Agent{Name: "a"}); err == nil {
		t.Fatal("expected PK conflict on duplicate create")
	}
}

func TestTransitionHappyPath(t *testing.T) {
	store, _ := newStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	id := session.NewSessionID()
	if err := store.CreateSession(ctx, session.Session{ID: id, AgentName: "a", Provider: "stub", State: session.StateCreated}); err != nil {
		t.Fatal(err)
	}
	for _, step := range []struct{ from, to session.SessionState }{
		{session.StateCreated, session.StateStarted},
		{session.StateStarted, session.StateRunning},
		{session.StateRunning, session.StateStopped},
	} {
		if err := store.TransitionSession(ctx, id, step.from, step.to, "test"); err != nil {
			t.Fatalf("%s->%s: %v", step.from, step.to, err)
		}
	}
	got, err := store.GetSession(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != session.StateStopped {
		t.Fatalf("expected stopped, got %s", got.State)
	}
	if got.StartedAt == nil {
		t.Fatal("expected started_at to be set")
	}
	if got.StoppedAt == nil {
		t.Fatal("expected stopped_at to be set")
	}
	if got.StopReason != "test" {
		t.Fatalf("expected stop_reason=test, got %q", got.StopReason)
	}
}

func TestTransitionCreatedToStopped(t *testing.T) {
	store, _ := newStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	id := session.NewSessionID()
	if err := store.CreateSession(ctx, session.Session{ID: id, AgentName: "a", Provider: "stub", State: session.StateCreated}); err != nil {
		t.Fatal(err)
	}
	if err := store.TransitionSession(ctx, id, session.StateCreated, session.StateStopped, "abort"); err != nil {
		t.Fatalf("created->stopped must be legal: %v", err)
	}
}

func TestTransitionInvalid(t *testing.T) {
	store, _ := newStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	id := session.NewSessionID()
	if err := store.CreateSession(ctx, session.Session{ID: id, AgentName: "a", Provider: "stub", State: session.StateCreated}); err != nil {
		t.Fatal(err)
	}
	illegal := []struct{ from, to session.SessionState }{
		{session.StateRunning, session.StateCreated},
		{session.StateStarted, session.StateCreated},
		{session.StateStopped, session.StateRunning},
		{session.StateStopped, session.StateCreated},
		{session.StateCreated, session.StateRunning},
	}
	for _, c := range illegal {
		if err := store.TransitionSession(ctx, id, c.from, c.to); !errors.Is(err, session.ErrInvalidTransition) {
			t.Errorf("%s->%s: expected ErrInvalidTransition, got %v", c.from, c.to, err)
		}
	}
}

func TestTransitionStaleFromState(t *testing.T) {
	store, _ := newStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	id := session.NewSessionID()
	if err := store.CreateSession(ctx, session.Session{ID: id, AgentName: "a", Provider: "stub", State: session.StateCreated}); err != nil {
		t.Fatal(err)
	}
	if err := store.TransitionSession(ctx, id, session.StateCreated, session.StateStarted); err != nil {
		t.Fatal(err)
	}
	err := store.TransitionSession(ctx, id, session.StateCreated, session.StateStarted)
	if !errors.Is(err, session.ErrStaleState) {
		t.Fatalf("expected ErrStaleState, got %v", err)
	}
}

func TestTransitionFromStoppedRejected(t *testing.T) {
	store, _ := newStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	id := session.NewSessionID()
	if err := store.CreateSession(ctx, session.Session{ID: id, AgentName: "a", Provider: "stub", State: session.StateCreated}); err != nil {
		t.Fatal(err)
	}
	if err := store.TransitionSession(ctx, id, session.StateCreated, session.StateStopped, "user"); err != nil {
		t.Fatal(err)
	}
	for _, to := range []session.SessionState{session.StateCreated, session.StateStarted, session.StateRunning} {
		if err := store.TransitionSession(ctx, id, session.StateStopped, to); !errors.Is(err, session.ErrInvalidTransition) {
			t.Errorf("stopped->%s: expected ErrInvalidTransition, got %v", to, err)
		}
	}
}

func TestUniqueActiveSession(t *testing.T) {
	store, _ := newStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	first := session.NewSessionID()
	if err := store.CreateSession(ctx, session.Session{ID: first, AgentName: "a", Provider: "stub", State: session.StateCreated}); err != nil {
		t.Fatal(err)
	}
	second := session.NewSessionID()
	if err := store.CreateSession(ctx, session.Session{ID: second, AgentName: "a", Provider: "stub", State: session.StateCreated}); err == nil {
		t.Fatal("expected partial-index conflict for second active session")
	}

	if err := store.TransitionSession(ctx, first, session.StateCreated, session.StateStopped, "done"); err != nil {
		t.Fatal(err)
	}
	third := session.NewSessionID()
	if err := store.CreateSession(ctx, session.Session{ID: third, AgentName: "a", Provider: "stub", State: session.StateCreated}); err != nil {
		t.Fatalf("after stopping first, should allow new active session: %v", err)
	}

	fourth := session.NewSessionID()
	if err := store.CreateSession(ctx, session.Session{ID: fourth, AgentName: "a", Provider: "stub", State: session.StateStopped}); err != nil {
		t.Fatalf("multiple stopped rows should be allowed: %v", err)
	}
}

func TestGetActiveSessionNone(t *testing.T) {
	store, _ := newStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	_, err := store.GetActiveSession(ctx, "a")
	if !errors.Is(err, session.ErrNotFound) {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestListAgents(t *testing.T) {
	store, _ := newStore(t)
	ctx := context.Background()
	for _, n := range []string{"alpha", "beta", "gamma"} {
		if err := store.CreateAgent(ctx, session.Agent{Name: n, Provider: "stub"}); err != nil {
			t.Fatal(err)
		}
	}
	agents, err := store.ListAgents(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(agents) != 3 {
		t.Fatalf("expected 3 agents, got %d", len(agents))
	}
}
