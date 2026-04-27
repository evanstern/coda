package main

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/evanstern/coda/internal/db"
	"github.com/evanstern/coda/internal/messages"
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
	store, _ := newTestStores(t)
	return store
}

func newTestStores(t *testing.T) (*session.Store, *messages.Store) {
	t.Helper()
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared&_pragma=foreign_keys(1)", t.Name())
	d, err := sql.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	d.SetMaxOpenConns(1)
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return session.NewStore(d), messages.NewStore(d)
}

func TestStartAgentNoProvider(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "lonely", Provider: ""}); err != nil {
		t.Fatal(err)
	}
	reg := session.NewProviderRegistry()
	var stdout, stderr bytes.Buffer
	code := startAgent(ctx, store, nil, reg, "lonely", &stdout, &stderr)
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
	code := startAgent(ctx, store, nil, reg, "a", &stdout, &stderr)
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
	if code := startAgent(ctx, store, nil, reg, "a", &stdout, &stderr); code != exitOK {
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

func TestSendRecvAck_EndToEnd(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())

	var stdout, stderr bytes.Buffer
	if code := run([]string{"agent", "new", "ash"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("agent new ash: code=%d stderr=%q", code, stderr.String())
	}
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"agent", "new", "zach"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("agent new zach: code=%d stderr=%q", code, stderr.String())
	}

	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"send", "ash", "zach", "note", `{"text":"hello"}`}, &stdout, &stderr); code != exitOK {
		t.Fatalf("send: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "sent: id=1 delivered=false") {
		t.Fatalf("unexpected send stdout: %q", stdout.String())
	}

	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"recv", "zach"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("recv: code=%d stderr=%q", code, stderr.String())
	}
	out := stdout.String()
	if !strings.Contains(out, "ID") || !strings.Contains(out, `{"text":"hello"}`) {
		t.Fatalf("recv missing row: %q", out)
	}

	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"ack", "1"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("ack: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "acked: 1") {
		t.Fatalf("unexpected ack stdout: %q", stdout.String())
	}

	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"recv", "zach"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("recv after ack: code=%d", code)
	}
	post := stdout.String()
	if strings.Contains(post, `{"text":"hello"}`) {
		t.Fatalf("expected no rows after ack, got %q", post)
	}
}

func TestSend_InvalidBodyAndType(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())

	var stdout, stderr bytes.Buffer
	if code := run([]string{"agent", "new", "ash"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("agent new: %d %q", code, stderr.String())
	}
	if code := run([]string{"agent", "new", "zach"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("agent new: %d %q", code, stderr.String())
	}
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"send", "ash", "zach", "note", "not-json"}, &stdout, &stderr); code != exitUserErr {
		t.Fatalf("expected exitUserErr for bad json, got %d", code)
	}
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"send", "ash", "zach", "bogus", `{}`}, &stdout, &stderr); code != exitUserErr {
		t.Fatalf("expected exitUserErr for bad type, got %d", code)
	}
}

func TestStopAgentRollsBackWhenProviderStopFails(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	provider := &stubProvider{stopErr: errors.New("boom")}
	reg := session.NewProviderRegistry()
	reg.Register("stub", provider)

	var stdout, stderr bytes.Buffer
	if code := startAgent(ctx, store, nil, reg, "a", &stdout, &stderr); code != exitOK {
		t.Fatalf("start: code=%d stderr=%q", code, stderr.String())
	}
	active, err := store.GetActiveSession(ctx, "a")
	if err != nil {
		t.Fatal(err)
	}
	priorState := active.State

	stdout.Reset()
	stderr.Reset()
	code := stopAgent(ctx, store, reg, "a", "done", &stdout, &stderr)
	if code != exitUserErr {
		t.Fatalf("expected exit %d, got %d (stderr=%q)", exitUserErr, code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "provider stop:") {
		t.Fatalf("expected provider stop error in stderr, got %q", stderr.String())
	}
	if provider.stopCalls != 1 {
		t.Fatalf("expected 1 stop call, got %d", provider.stopCalls)
	}

	got, err := store.GetSession(ctx, active.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != priorState {
		t.Fatalf("expected rollback to %s, got %s", priorState, got.State)
	}
	if got.StoppedAt != nil {
		t.Fatalf("expected stopped_at cleared after rollback, got %v", got.StoppedAt)
	}
	if got.StopReason != "" {
		t.Fatalf("expected stop_reason cleared after rollback, got %q", got.StopReason)
	}
}
