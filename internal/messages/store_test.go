package messages_test

import (
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

func newStore(t *testing.T) *messages.Store {
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
	return messages.NewStore(d)
}

func TestInsert_AssignsID(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()
	id1, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{"x":1}`))
	if err != nil {
		t.Fatal(err)
	}
	id2, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{"x":2}`))
	if err != nil {
		t.Fatal(err)
	}
	if id1 == 0 || id2 == 0 || id2 == id1 {
		t.Fatalf("expected distinct nonzero ids, got %d %d", id1, id2)
	}
}

func TestInsert_DefaultsCreatedAt(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()
	id, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	got, err := store.Get(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if got.CreatedAt.IsZero() {
		t.Fatalf("expected non-zero created_at, got %v", got.CreatedAt)
	}
}

func TestMarkDelivered_AndAcked(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()
	id, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.MarkDelivered(ctx, id); err != nil {
		t.Fatal(err)
	}
	got, err := store.Get(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if got.DeliveredAt == nil {
		t.Fatalf("expected delivered_at set")
	}
	if got.AckedAt != nil {
		t.Fatalf("expected acked_at unset")
	}
	if err := store.MarkAcked(ctx, id); err != nil {
		t.Fatal(err)
	}
	got, err = store.Get(ctx, id)
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
	store := newStore(t)
	ctx := context.Background()
	var ids []int64
	for i := 0; i < 3; i++ {
		id, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(fmt.Sprintf(`{"i":%d}`, i)))
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	// Different recipient -- must be excluded.
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
	store := newStore(t)
	ctx := context.Background()
	var ids []int64
	for i := 0; i < 3; i++ {
		id, err := store.Insert(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
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
