package messages_test

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"testing"

	"github.com/evanstern/coda/internal/db"
	"github.com/evanstern/coda/internal/messages"
	"github.com/evanstern/coda/internal/session"
	_ "modernc.org/sqlite"
)

type testStoreBundle struct {
	db       *sql.DB
	store    *messages.Store
	sessions *session.Store
}

var storeBundles = map[*messages.Store]*testStoreBundle{}

func newStoreBundle(t *testing.T, agents ...string) *testStoreBundle {
	t.Helper()
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared&_pragma=foreign_keys(1)", t.Name())
	d, err := sql.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	d.SetMaxOpenConns(1)
	t.Cleanup(func() { d.Close() })
	ctx := context.Background()
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	sessStore := session.NewStore(d)
	for _, name := range agents {
		if err := sessStore.CreateAgent(ctx, session.Agent{Name: name, Provider: "stub"}); err != nil {
			t.Fatal(err)
		}
	}
	store := messages.NewStore(d)
	bundle := &testStoreBundle{db: d, store: store, sessions: sessStore}
	storeBundles[store] = bundle
	t.Cleanup(func() { delete(storeBundles, store) })
	return bundle
}

func newStoreWithAgents(t *testing.T, agents ...string) *messages.Store {
	t.Helper()
	return newStoreBundle(t, agents...).store
}

func newStoreWithSessions(t *testing.T, agents ...string) (*messages.Store, *session.Store) {
	t.Helper()
	b := newStoreBundle(t, agents...)
	return b.store, b.sessions
}

func storeRawDB(t *testing.T, s *messages.Store) *sql.DB {
	t.Helper()
	b, ok := storeBundles[s]
	if !ok {
		t.Fatalf("store not registered with a bundle")
	}
	return b.db
}

func TestInsert_AssignsID(t *testing.T) {
	store := newStoreWithAgents(t, "ash", "zach")
	ctx := context.Background()
	m1, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{"x":1}`))
	if err != nil {
		t.Fatal(err)
	}
	m2, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{"x":2}`))
	if err != nil {
		t.Fatal(err)
	}
	if m1.ID == 0 || m2.ID == 0 || m2.ID == m1.ID {
		t.Fatalf("expected distinct nonzero ids, got %d %d", m1.ID, m2.ID)
	}
}

func TestInsert_DefaultsCreatedAt(t *testing.T) {
	store := newStoreWithAgents(t, "ash", "zach")
	ctx := context.Background()
	m, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	if m.CreatedAt.IsZero() {
		t.Fatalf("expected non-zero created_at, got %v", m.CreatedAt)
	}
}

func TestMarkDelivered_AndAcked(t *testing.T) {
	store := newStoreWithAgents(t, "ash", "zach")
	ctx := context.Background()
	m, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.MarkDelivered(ctx, m.ID); err != nil {
		t.Fatal(err)
	}
	got, err := store.Get(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.DeliveredAt == nil {
		t.Fatalf("expected delivered_at set")
	}
	if got.AckedAt != nil {
		t.Fatalf("expected acked_at unset")
	}
	if err := store.MarkAcked(ctx, m.ID); err != nil {
		t.Fatal(err)
	}
	got, err = store.Get(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.AckedAt == nil {
		t.Fatalf("expected acked_at set")
	}
	if err := store.MarkAcked(ctx, 999999); !errors.Is(err, session.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for unknown id, got %v", err)
	}
}

func TestListUnacked_OrderingAndScope(t *testing.T) {
	store := newStoreWithAgents(t, "ash", "zach", "kim")
	ctx := context.Background()
	var ids []int64
	for i := 0; i < 3; i++ {
		m, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(fmt.Sprintf(`{"i":%d}`, i)))
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, m.ID)
	}
	if _, err := store.Insert(ctx, "ash", "kim", messages.TypeNote, []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	if err := store.MarkAcked(ctx, ids[1]); err != nil {
		t.Fatal(err)
	}
	got, err := store.ListUnacked(ctx, "zach")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(got))
	}
	if got[0].ID != ids[0] || got[1].ID != ids[2] {
		t.Fatalf("expected oldest-first %d,%d, got %d,%d", ids[0], ids[2], got[0].ID, got[1].ID)
	}
}

func TestListUndelivered(t *testing.T) {
	store := newStoreWithAgents(t, "ash", "zach")
	ctx := context.Background()
	var ids []int64
	for i := 0; i < 3; i++ {
		m, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, m.ID)
	}
	if err := store.MarkDelivered(ctx, ids[1]); err != nil {
		t.Fatal(err)
	}
	got, err := store.ListUndelivered(ctx, "zach")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].ID != ids[0] || got[1].ID != ids[2] {
		t.Fatalf("unexpected: %+v", got)
	}
}

func TestListUndelivered_SkipsAcked(t *testing.T) {
	store := newStoreWithAgents(t, "ash", "zach")
	ctx := context.Background()
	m, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.MarkAcked(ctx, m.ID); err != nil {
		t.Fatal(err)
	}
	got, err := store.ListUndelivered(ctx, "zach")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("expected acked-but-undelivered to be excluded, got %+v", got)
	}
}

func TestInsertGet_BinaryBodyRoundTrip(t *testing.T) {
	store := newStoreWithAgents(t, "ash", "zach")
	ctx := context.Background()
	body := []byte{0x00, 0xff, 0xfe, 0x01, 0x02, 0x80}
	m, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, body)
	if err != nil {
		t.Fatal(err)
	}
	got, err := store.Get(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.Body, body) {
		t.Fatalf("body mismatch: got %v want %v", got.Body, body)
	}
}

func TestInsert_FKRejectsUnknownRecipient(t *testing.T) {
	store := newStoreWithAgents(t, "ash")
	ctx := context.Background()
	if _, err := store.Insert(ctx, "ash", "ghost", messages.TypeNote, []byte(`{}`)); err == nil {
		t.Fatalf("expected FK violation for unknown recipient")
	}
}

func TestDeleteAgent_RestrictedByMessageFK(t *testing.T) {
	store, sessStore := newStoreWithSessions(t, "ash", "zach")
	ctx := context.Background()
	if _, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	_ = sessStore
	rawDB := storeRawDB(t, store)
	if _, err := rawDB.ExecContext(ctx, `DELETE FROM agents WHERE name = ?`, "zach"); err == nil {
		t.Fatalf("expected RESTRICT FK violation when deleting agent with messages")
	}
}

func TestMigration003_PreservesExistingFixtures(t *testing.T) {
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared&_pragma=foreign_keys(1)", t.Name())
	d, err := sql.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	d.SetMaxOpenConns(1)
	t.Cleanup(func() { d.Close() })
	ctx := context.Background()
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	sessStore := session.NewStore(d)
	if err := sessStore.CreateAgent(ctx, session.Agent{Name: "ash", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	if err := sessStore.CreateAgent(ctx, session.Agent{Name: "zach", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	store := messages.NewStore(d)
	body := []byte(`{"hello":"world"}`)
	m, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, body)
	if err != nil {
		t.Fatal(err)
	}
	got, err := store.Get(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.Body, body) {
		t.Fatalf("post-migration body mismatch")
	}
}

func TestValidateType(t *testing.T) {
	for _, ok := range messages.AllTypes {
		if err := messages.ValidateType(ok); err != nil {
			t.Errorf("expected ok for %q, got %v", ok, err)
		}
	}
	if err := messages.ValidateType(messages.MessageType("bogus")); err == nil {
		t.Errorf("expected error for unknown type")
	}
}
