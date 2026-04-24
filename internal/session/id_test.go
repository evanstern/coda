package session_test

import (
	"sort"
	"testing"

	"github.com/evanstern/coda/internal/session"
)

func TestNewSessionIDDistinctSortable(t *testing.T) {
	const n = 1000
	ids := make([]string, n)
	seen := make(map[string]struct{}, n)
	for i := range ids {
		id := session.NewSessionID()
		if _, dup := seen[id]; dup {
			t.Fatalf("duplicate ULID at i=%d: %s", i, id)
		}
		seen[id] = struct{}{}
		ids[i] = id
	}
	if !sort.StringsAreSorted(ids) {
		t.Fatal("expected monotonic ULIDs to be lexically sorted by creation order")
	}
	if len(ids[0]) != 26 {
		t.Fatalf("expected 26-char ULID, got %d", len(ids[0]))
	}
}
