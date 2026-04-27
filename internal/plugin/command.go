package plugin

import (
	"context"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"sort"
)

// ReservedSubcommands are the core CLI verbs plugins are forbidden
// from shadowing. Attempts produce a load-time error so the plugin
// author sees the conflict.
var ReservedSubcommands = map[string]struct{}{
	"version": {},
	"agent":   {},
	"send":    {},
	"recv":    {},
	"ack":     {},
	"feature": {},
	"mcp":     {},
	"help":    {},
}

// CommandRegistration binds a command name to a plugin's executable
// path (resolved absolute) plus the source plugin name for error
// reporting.
type CommandRegistration struct {
	Name        string
	Plugin      string
	Exec        string
	Description string
}

// CommandRegistry is the set of plugin-contributed CLI commands.
type CommandRegistry struct {
	commands map[string]CommandRegistration
}

// BuildCommandRegistry walks plugins, validates their command
// declarations against ReservedSubcommands, and returns a registry.
// A duplicate or reserved name is a load-time error; the error
// message names the offending plugin and command.
func BuildCommandRegistry(plugins []Plugin) (*CommandRegistry, error) {
	r := &CommandRegistry{commands: map[string]CommandRegistration{}}
	for _, p := range plugins {
		names := make([]string, 0, len(p.Manifest.Provides.Commands))
		for n := range p.Manifest.Provides.Commands {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, name := range names {
			spec := p.Manifest.Provides.Commands[name]
			if _, reserved := ReservedSubcommands[name]; reserved {
				return nil, fmt.Errorf("plugin %s: command %q shadows reserved coda subcommand", p.Manifest.Name, name)
			}
			if existing, ok := r.commands[name]; ok {
				return nil, fmt.Errorf("plugin %s: command %q already registered by plugin %s", p.Manifest.Name, name, existing.Plugin)
			}
			full := spec.Exec
			if !filepath.IsAbs(full) {
				full = filepath.Join(p.Root, spec.Exec)
			}
			r.commands[name] = CommandRegistration{
				Name:        name,
				Plugin:      p.Manifest.Name,
				Exec:        full,
				Description: spec.Description,
			}
		}
	}
	return r, nil
}

// Lookup returns the registration for name, and a bool indicating
// whether it exists.
func (r *CommandRegistry) Lookup(name string) (CommandRegistration, bool) {
	if r == nil {
		return CommandRegistration{}, false
	}
	c, ok := r.commands[name]
	return c, ok
}

// Names returns sorted command names.
func (r *CommandRegistry) Names() []string {
	if r == nil {
		return nil
	}
	out := make([]string, 0, len(r.commands))
	for n := range r.commands {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// Dispatch runs the plugin command with args. Stdin/stdout/stderr
// pass through. Exit code: 0 on success; the plugin's exit code
// from a non-zero exit; 1 on spawn failure (with the error printed
// to stderr); 2 if name doesn't resolve to a registered command.
func (r *CommandRegistry) Dispatch(ctx context.Context, name string, args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	reg, ok := r.Lookup(name)
	if !ok {
		fmt.Fprintf(stderr, "unknown command: %s\n", name)
		return 2
	}
	cmd := exec.CommandContext(ctx, reg.Exec, args...)
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	err := cmd.Run()
	if err == nil {
		return 0
	}
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode()
	}
	fmt.Fprintf(stderr, "error: run %s: %v\n", reg.Exec, err)
	return 1
}
