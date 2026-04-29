package session

import (
	"fmt"
	"sync"
	"time"
)

// Provider runs agent sessions. Core defines the contract; plugins
// implement it. Coda ships no provider itself.
type Provider interface {
	Start(agent Agent, config ProviderConfig) (sessionID string, err error)
	Stop(sessionID string) error
	Deliver(sessionID string, msg Message) (delivered bool, err error)
	Health(sessionID string) (Status, error)
	Output(sessionID string, since string) ([]Message, error)
	Attach(sessionID string) error
}

// Message is the payload Deliver and Output move between coda and a
// provider session. It is the same shape used by the messaging
// primitive (card #170), defined here to keep the Provider interface
// self-contained for now. Card #170 may move it.
//
// Cursor is opaque to coda — plugins define its format and coda
// round-trips it unchanged between Output calls.
type Message struct {
	ID        string
	From      string
	To        string
	Type      string
	Body      []byte
	CreatedAt time.Time
	// Cursor is an opaque, plugin-defined value for resuming
	// Output(). Providers MUST return Output() messages in the
	// same stream order they want cursor advancement to follow
	// (typically oldest to newest). Coda does not compare, sort,
	// or interpret cursor values; after a successful Output() call
	// it persists the Cursor from the last message in the returned
	// slice whose Cursor is non-empty, and echoes that exact value
	// back on the next call's since argument. If no message in the
	// slice has a non-empty Cursor, coda leaves the persisted
	// cursor unchanged. Empty string means "no cursor yet".
	Cursor string `json:",omitempty"`
}

// Status is a provider-reported session health snapshot.
type Status struct {
	State   string
	Healthy bool
	Detail  string
}

// ProviderConfig is opaque provider-specific configuration. Core
// treats it as a map so it does not need to know about provider
// specifics.
type ProviderConfig map[string]string

// ProviderRegistry maps a provider name to its implementation. A
// later card wires plugin-registered providers into it; for now it is
// populated by callers (tests) and is always empty at CLI startup.
type ProviderRegistry struct {
	mu        sync.RWMutex
	providers map[string]Provider
}

// NewProviderRegistry returns an empty registry.
func NewProviderRegistry() *ProviderRegistry {
	return &ProviderRegistry{providers: map[string]Provider{}}
}

// Register adds a provider under the given name. Re-registering the
// same name replaces the previous value.
func (r *ProviderRegistry) Register(name string, p Provider) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.providers[name] = p
}

// Get returns the provider registered under name, and a bool
// indicating whether such a provider exists. Callers that need to
// produce the user-facing "no provider registered" error construct
// a *NoProviderError at the call site.
func (r *ProviderRegistry) Get(providerName string) (Provider, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.providers[providerName]
	return p, ok
}

// NoProviderError is returned when an agent's provider is empty or
// unregistered. Error text matches the spec.
type NoProviderError struct {
	AgentName string
	Provider  string
}

func (e *NoProviderError) Error() string {
	return fmt.Sprintf("no provider registered for agent %s (agent.provider=%s)", e.AgentName, e.Provider)
}
