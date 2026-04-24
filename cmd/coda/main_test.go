package main

import (
	"bytes"
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"

	"github.com/evanstern/coda/internal/db"
	"github.com/evanstern/coda/internal/session"
	_ "modernc.org/sqlite"
)

type stubProvider struct {
	startCalls int
	stopCalls  int
	startErr   error
	stopErr    error
}

func (s *stubProvider) Start(a session.Agent, _ session.ProviderConfig) (string, error) {
	s.startCalls++
	return "stub-" + a.Name, s.startErr
}
func (s *stubProvider) Stop(_ string) error { s.stopCalls++; return s.stopErr }
func (s *stubProvider) Deliver(_ string, _ session.Message) (bool, error) {
	return true, nil
}
func (s *stubProvider) Health(_ string) (session.Status, error) {
	return session.Status{State: "running", Healthy: true}, nil
}
func (s *stubProvider) Output(_ string, _ *time.Time) ([]session.Message, error) {
	return nil, nil
}
func (s *stubProvider) Attach(_ string) error { return nil }

func newTestStore(t *testing.T) *session.Store {
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
	return session.NewStore(d)
}

func TestStartAgentNoProvider(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "lonely", Provider: ""}); err != nil {
		t.Fatal(err)
	}
	reg := session.NewProviderRegistry()
	var stdout, stderr bytes.Buffer
	code := startAgent(ctx, store, reg, "lonely", &stdout, &stderr)
	if code != exitUserErr {
		t.Fatalf("expected exit %d, got %d (stderr=%q)", exitUserErr, code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "no provider registered for agent lonely") {
		t.Fatalf("unexpected error text: %q", stderr.String())
	}
}

func TestStartAgentUnregisteredProvider(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "ghost"}); err != nil {
		t.Fatal(err)
	}
	reg := session.NewProviderRegistry()
	var stdout, stderr bytes.Buffer
	code := startAgent(ctx, store, reg, "a", &stdout, &stderr)
	if code != exitUserErr {
		t.Fatalf("expected exit %d, got %d", exitUserErr, code)
	}
	if !strings.Contains(stderr.String(), "agent.provider=ghost") {
		t.Fatalf("expected provider name in error, got %q", stderr.String())
	}
}

func TestStartStopAgentHappyPath(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	provider := &stubProvider{}
	reg := session.NewProviderRegistry()
	reg.Register("stub", provider)

	var stdout, stderr bytes.Buffer
	if code := startAgent(ctx, store, reg, "a", &stdout, &stderr); code != exitOK {
		t.Fatalf("start: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.HasPrefix(stdout.String(), "started: ") {
		t.Fatalf("expected stdout to start with 'started: ', got %q", stdout.String())
	}
	if provider.startCalls != 1 {
		t.Fatalf("expected 1 start call, got %d", provider.startCalls)
	}

	active, err := store.GetActiveSession(ctx, "a")
	if err != nil {
		t.Fatal(err)
	}
	if active.State != session.StateStarted {
		t.Fatalf("expected started, got %s", active.State)
	}

	stdout.Reset()
	stderr.Reset()
	if code := stopAgent(ctx, store, reg, "a", "done", &stdout, &stderr); code != exitOK {
		t.Fatalf("stop: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.HasPrefix(stdout.String(), "stopped: ") {
		t.Fatalf("expected stdout to start with 'stopped: ', got %q", stdout.String())
	}
	if provider.stopCalls != 1 {
		t.Fatalf("expected 1 stop call, got %d", provider.stopCalls)
	}
	stopped, err := store.GetSession(ctx, active.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stopped.State != session.StateStopped || stopped.StopReason != "done" {
		t.Fatalf("unexpected stopped session: %+v", stopped)
	}
}
