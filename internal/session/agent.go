package session

import (
	"fmt"
	"regexp"
	"time"
)

// Agent is a named actor that a Provider can run sessions for. The
// ConfigDir field points at the agent's identity directory once the
// identity plugin (card #169) populates it; for now it is always empty.
type Agent struct {
	Name      string
	Provider  string
	ConfigDir string
	CreatedAt time.Time
}

const maxAgentNameLen = 64

var agentNameRE = regexp.MustCompile(`^[A-Za-z0-9-]+$`)

// ValidateAgentName enforces the agent-name rule from the spec:
// alphanumeric plus dashes, 1..64 chars.
func ValidateAgentName(name string) error {
	if name == "" {
		return fmt.Errorf("agent name must not be empty")
	}
	if len(name) > maxAgentNameLen {
		return fmt.Errorf("agent name %q exceeds %d chars", name, maxAgentNameLen)
	}
	if !agentNameRE.MatchString(name) {
		return fmt.Errorf("agent name %q must match %s", name, agentNameRE.String())
	}
	return nil
}
