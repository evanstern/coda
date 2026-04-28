package plugin

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/evanstern/coda/internal/session"
)

// SubprocessProvider implements session.Provider by spawning a plugin
// executable for each method. The provider exec contract is published
// at docs/plugin-contracts/providers.md.
type SubprocessProvider struct {
	Name string
	Exec string
	Root string

	ctx context.Context
}

// NewSubprocessProvider returns a provider rooted at root that runs
// exec (an absolute path or a path relative to root). name is used in
// error messages and the --agent flag.
func NewSubprocessProvider(name, root, execPath string) *SubprocessProvider {
	full := execPath
	if !filepath.IsAbs(full) {
		full = filepath.Join(root, execPath)
	}
	return &SubprocessProvider{
		Name: name,
		Exec: full,
		Root: root,
		ctx:  context.Background(),
	}
}

// WithContext returns a copy of p that uses ctx for subprocess
// lifetime control.
func (p *SubprocessProvider) WithContext(ctx context.Context) *SubprocessProvider {
	cp := *p
	cp.ctx = ctx
	return &cp
}

func (p *SubprocessProvider) command(args ...string) *exec.Cmd {
	ctx := p.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	cmd := exec.CommandContext(ctx, p.Exec, args...)
	return cmd
}

func (p *SubprocessProvider) runJSON(stdin []byte, args ...string) ([]byte, error) {
	cmd := p.command(args...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = strings.TrimSpace(stdout.String())
		}
		return nil, fmt.Errorf("plugin %s %s: %w: %s", p.Name, args[0], err, msg)
	}
	return stdout.Bytes(), nil
}

// Start spawns "<exec> start --agent=<name>" with the agent config as
// JSON on stdin. Stdout's trimmed first line is taken as the session
// ID.
func (p *SubprocessProvider) Start(agent session.Agent, config session.ProviderConfig) (string, error) {
	cfg, err := json.Marshal(config)
	if err != nil {
		return "", fmt.Errorf("marshal config: %w", err)
	}
	out, err := p.runJSON(cfg, "start", "--agent="+agent.Name)
	if err != nil {
		return "", err
	}
	id := strings.TrimSpace(string(out))
	if id == "" {
		return "", fmt.Errorf("plugin %s start: empty session id", p.Name)
	}
	return id, nil
}

// Stop spawns "<exec> stop <sessionID>". Non-zero exit becomes an
// error.
func (p *SubprocessProvider) Stop(sessionID string) error {
	_, err := p.runJSON(nil, "stop", sessionID)
	return err
}

// Deliver spawns "<exec> deliver <sessionID>" with the message JSON
// on stdin. The plugin must respond with {"delivered": bool}.
func (p *SubprocessProvider) Deliver(sessionID string, msg session.Message) (bool, error) {
	body, err := json.Marshal(msg)
	if err != nil {
		return false, fmt.Errorf("marshal message: %w", err)
	}
	out, err := p.runJSON(body, "deliver", sessionID)
	if err != nil {
		return false, err
	}
	var resp struct {
		Delivered bool `json:"delivered"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(out), &resp); err != nil {
		return false, fmt.Errorf("plugin %s deliver: parse response: %w", p.Name, err)
	}
	return resp.Delivered, nil
}

// Health spawns "<exec> health <sessionID>" and parses the
// {state, healthy, detail} JSON.
func (p *SubprocessProvider) Health(sessionID string) (session.Status, error) {
	out, err := p.runJSON(nil, "health", sessionID)
	if err != nil {
		return session.Status{}, err
	}
	var s session.Status
	if err := json.Unmarshal(bytes.TrimSpace(out), &s); err != nil {
		return session.Status{}, fmt.Errorf("plugin %s health: parse response: %w", p.Name, err)
	}
	return s, nil
}

// Output spawns "<exec> output <sessionID> [--since=<rfc3339>]" and
// parses a JSON array of session.Message.
func (p *SubprocessProvider) Output(sessionID string, since *time.Time) ([]session.Message, error) {
	args := []string{"output", sessionID}
	if since != nil {
		args = append(args, "--since="+since.UTC().Format(time.RFC3339Nano))
	}
	out, err := p.runJSON(nil, args...)
	if err != nil {
		return nil, err
	}
	trimmed := bytes.TrimSpace(out)
	if len(trimmed) == 0 {
		return nil, nil
	}
	var msgs []session.Message
	if err := json.Unmarshal(trimmed, &msgs); err != nil {
		return nil, fmt.Errorf("plugin %s output: parse response: %w", p.Name, err)
	}
	return msgs, nil
}

// Attach spawns "<exec> attach <sessionID>" with the controlling
// terminal's std streams inherited so the plugin's REPL or TUI can
// drive the user's terminal directly. Non-zero exit becomes an
// *exec.ExitError; stderr is not wrapped because it has already been
// streamed to the terminal.
func (p *SubprocessProvider) Attach(sessionID string) error {
	cmd := p.command("attach", sessionID)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

var _ session.Provider = (*SubprocessProvider)(nil)
