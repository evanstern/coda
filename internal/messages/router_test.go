package messages_test

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/evanstern/coda/internal/db"
	"github.com/evanstern/coda/internal/messages"
	"github.com/evanstern/coda/internal/session"
	_ "modernc.org/sqlite"
)

type fakeProvider struct {
	mu        sync.Mutex
	delivered []session.Message
	deliverFn func(sessionID string, msg session.Message) (bool, error)
}

func (f *fakeProvider) Start(_ session.Agent, _ session.ProviderConfig) (string, error) {
	return "", nil
}
func (f *fakeProvider) Stop(_ string) error { return nil }
func (f *fakeProvider) Deliver(sessionID string, msg session.Message) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.deliverFn != nil {
		return f.deliverFn(sessionID, msg)
	}
	f.delivered = append(f.delivered, msg)
	return true, nil
}
func (f *fakeProvider) Health(_ string) (session.Status, error) { return session.Status{}, nil }
func (f *fakeProvider) Output(_ string, _ *time.Time) ([]session.Message, error) {
	return nil, nil
}
func (f *fakeProvider) Attach(_ string) error { return nil }

type routerFixture struct {
	router      *messages.Router
	sessions    *session.Store
	msgs        *messages.Store
	provider    *fakeProvider
	registry    *session.ProviderRegistry
	recipientID string
}

func newRouterFixture(t *testing.T, withActiveSession bool) routerFixture {
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
	sessStore := session.NewStore(d)
	msgStore := messages.NewStore(d)
	ctx := context.Background()
	if err := sessStore.CreateAgent(ctx, session.Agent{Name: "ash", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	if err := sessStore.CreateAgent(ctx, session.Agent{Name: "zach", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	provider := &fakeProvider{}
	reg := session.NewProviderRegistry()
	reg.Register("stub", provider)
	fix := routerFixture{
		router:   messages.NewRouter(msgStore, sessStore, reg),
		sessions: sessStore,
		msgs:     msgStore,
		provider: provider,
		registry: reg,
	}
	if withActiveSession {
		sess := session.Session{
			ID:        session.NewSessionID(),
			AgentName: "zach",
			Provider:  "stub",
			State:     session.StateCreated,
		}
		if err := sessStore.CreateSession(ctx, sess); err != nil {
			t.Fatal(err)
		}
		if err := sessStore.TransitionSession(ctx, sess.ID, session.StateCreated, session.StateStarted); err != nil {
			t.Fatal(err)
		}
		fix.recipientID = sess.ID
	}
	return fix
}

func TestSend_Delivered(t *testing.T) {
	fix := newRouterFixture(t, true)
	ctx := context.Background()
	id, delivered, err := fix.router.Send(ctx, "ash", "zach", messages.TypeNote, []byte(`{"x":1}`))
	if err != nil {
		t.Fatal(err)
	}
	if !delivered {
		t.Fatalf("expected delivered=true")
	}
	got, err := fix.msgs.Get(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if got.DeliveredAt == nil {
		t.Fatalf("expected delivered_at set")
	}
	if len(fix.provider.delivered) != 1 {
		t.Fatalf("expected 1 deliver call, got %d", len(fix.provider.delivered))
	}
}

func TestSend_NoActiveSession(t *testing.T) {
	fix := newRouterFixture(t, false)
	ctx := context.Background()
	id, delivered, err := fix.router.Send(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	if delivered {
		t.Fatalf("expected delivered=false")
	}
	got, err := fix.msgs.Get(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if got.DeliveredAt != nil {
		t.Fatalf("expected delivered_at unset")
	}
}

func TestSend_TransportFailure(t *testing.T) {
	fix := newRouterFixture(t, true)
	fix.provider.deliverFn = func(_ string, _ session.Message) (bool, error) {
		return false, errors.New("transport boom")
	}
	ctx := context.Background()
	id, delivered, err := fix.router.Send(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`))
	if err == nil {
		t.Fatalf("expected error from transport failure")
	}
	if delivered {
		t.Fatalf("expected delivered=false")
	}
	got, err := fix.msgs.Get(ctx, id)
	if err != nil {
		t.Fatalf("expected row to still exist: %v", err)
	}
	if got.DeliveredAt != nil {
		t.Fatalf("expected delivered_at unset")
	}
}

func TestSend_UnknownRecipient(t *testing.T) {
	fix := newRouterFixture(t, true)
	ctx := context.Background()
	_, _, err := fix.router.Send(ctx, "ash", "ghost", messages.TypeNote, []byte(`{}`))
	if !errors.Is(err, session.ErrNotFound) {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestDrain_DeliversPending(t *testing.T) {
	fix := newRouterFixture(t, true)
	ctx := context.Background()
	for i := 0; i < 3; i++ {
		if _, err := fix.msgs.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`)); err != nil {
			t.Fatal(err)
		}
	}
	n, err := fix.router.Drain(ctx, "zach")
	if err != nil {
		t.Fatal(err)
	}
	if n != 3 {
		t.Fatalf("expected 3 delivered, got %d", n)
	}
	n, err = fix.router.Drain(ctx, "zach")
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("expected idempotent 0, got %d", n)
	}
}

func TestDrain_PartialFailure(t *testing.T) {
	fix := newRouterFixture(t, true)
	ctx := context.Background()
	var ids []int64
	for i := 0; i < 3; i++ {
		m, err := fix.msgs.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, m.ID)
	}
	fix.provider.deliverFn = func(_ string, msg session.Message) (bool, error) {
		if msg.ID == fmt.Sprintf("%d", ids[1]) {
			return false, errors.New("transport boom")
		}
		return true, nil
	}
	n, err := fix.router.Drain(ctx, "zach")
	if err == nil {
		t.Fatalf("expected error from partial failure")
	}
	if n != 2 {
		t.Fatalf("expected 2 delivered, got %d", n)
	}
	got, err := fix.msgs.Get(ctx, ids[1])
	if err != nil {
		t.Fatal(err)
	}
	if got.DeliveredAt != nil {
		t.Fatalf("expected failed message to remain undelivered")
	}
}
