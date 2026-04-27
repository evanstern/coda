// Package messages provides the typed messaging layer: storage,
// routing, and CLI primitives. Providers implement transport.
package messages

import (
	"fmt"
	"time"

	"github.com/evanstern/coda/internal/session"
)

// MessageType is the enum of valid message types.
type MessageType string

const (
	TypeNote       MessageType = "note"
	TypeBrief      MessageType = "brief"
	TypeCompletion MessageType = "completion"
	TypeStatus     MessageType = "status"
	TypeEscalation MessageType = "escalation"
)

// AllTypes is the canonical ordered list, for usage strings and validation.
var AllTypes = []MessageType{TypeNote, TypeBrief, TypeCompletion, TypeStatus, TypeEscalation}

// ValidateType returns an error if t is not one of AllTypes.
func ValidateType(t MessageType) error {
	for _, v := range AllTypes {
		if v == t {
			return nil
		}
	}
	return fmt.Errorf("invalid message type %q", string(t))
}

// Stored is the on-disk row. Mirrors the schema. Use this for storage;
// session.Message is the wire shape used by Provider.Deliver.
type Stored struct {
	ID          int64
	Sender      string
	Recipient   string
	Type        MessageType
	Body        []byte
	CreatedAt   time.Time
	DeliveredAt *time.Time
	AckedAt     *time.Time
}

// ToWire returns the session.Message form for provider delivery.
func (s Stored) ToWire() session.Message {
	return session.Message{
		ID:        fmt.Sprintf("%d", s.ID),
		From:      s.Sender,
		To:        s.Recipient,
		Type:      string(s.Type),
		Body:      s.Body,
		CreatedAt: s.CreatedAt,
	}
}
