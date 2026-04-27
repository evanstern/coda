package messages

import (
	"context"
	"errors"
	"fmt"

	"github.com/evanstern/coda/internal/session"
)

// Router resolves a recipient name to an active session and delivers
// via the provider. Stateless; takes deps via parameters.
type Router struct {
	Messages *Store
	Sessions *session.Store
	Registry *session.ProviderRegistry
}

// NewRouter wires the router's dependencies.
func NewRouter(messages *Store, sessions *session.Store, registry *session.ProviderRegistry) *Router {
	return &Router{Messages: messages, Sessions: sessions, Registry: registry}
}

// Send inserts a message, looks up the recipient's active session,
// resolves the provider, calls Deliver, and updates delivered_at on
// success. If the recipient has no active session, the message is
// stored undelivered (drain-on-start handles it later). Returns the
// stored message ID and a "delivered" flag.
//
// Storage failure is fatal; transport failure is surfaced but does
// NOT delete the row (it'll drain later).
func (r *Router) Send(ctx context.Context, sender, recipient string, t MessageType, body []byte) (int64, bool, error) {
	if err := ValidateType(t); err != nil {
		return 0, false, err
	}
	if _, err := r.Sessions.GetAgent(ctx, recipient); err != nil {
		return 0, false, err
	}
	stored, err := r.Messages.Insert(ctx, sender, recipient, t, body)
	if err != nil {
		return 0, false, err
	}
	delivered, err := r.deliver(ctx, *stored)
	if err != nil {
		return stored.ID, false, err
	}
	return stored.ID, delivered, nil
}

// Drain delivers all undelivered messages for the given recipient via
// the registered provider for that recipient's active session. Used
// by `coda agent start` after the session transitions to started.
// Best-effort: returns the number successfully delivered and the
// first error if any.
func (r *Router) Drain(ctx context.Context, recipient string) (int, error) {
	pending, err := r.Messages.ListUndelivered(ctx, recipient)
	if err != nil {
		return 0, err
	}
	var firstErr error
	delivered := 0
	for _, m := range pending {
		ok, err := r.deliver(ctx, m)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if ok {
			delivered++
		}
	}
	return delivered, firstErr
}

// deliver resolves the recipient's active session and provider,
// invokes Deliver, and marks delivered_at on success. If there is no
// active session, returns (false, nil) — the row stays undelivered.
func (r *Router) deliver(ctx context.Context, m Stored) (bool, error) {
	sess, err := r.Sessions.GetActiveSession(ctx, m.Recipient)
	if err != nil {
		if errors.Is(err, session.ErrNotFound) {
			return false, nil
		}
		return false, err
	}
	provider, ok := r.Registry.Get(sess.Provider)
	if !ok {
		return false, &session.NoProviderError{AgentName: m.Recipient, Provider: sess.Provider}
	}
	delivered, err := provider.Deliver(sess.ID, m.ToWire())
	if err != nil {
		return false, fmt.Errorf("provider deliver: %w", err)
	}
	if !delivered {
		return false, nil
	}
	if err := r.Messages.MarkDelivered(ctx, m.ID); err != nil {
		return false, err
	}
	return true, nil
}
