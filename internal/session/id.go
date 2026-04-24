package session

import "github.com/oklog/ulid/v2"

// NewSessionID returns a monotonic ULID string suitable as a session
// primary key. 26-char Crockford-base32, lexically sortable by
// creation time.
func NewSessionID() string {
	return ulid.Make().String()
}
