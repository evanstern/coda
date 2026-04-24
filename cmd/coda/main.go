// Package main is the entrypoint for the coda CLI.
package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/evanstern/coda/internal/db"
	"github.com/evanstern/coda/internal/session"
)

// Version is the coda CLI version. Set via -ldflags at build time.
var Version = "dev"

// exit codes (will move to a shared package once more commands need them)
const (
	exitOK      = 0
	exitUserErr = 1
	exitUsage   = 2
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		printUsage(stderr)
		return exitUsage
	}
	switch args[0] {
	case "version":
		fmt.Fprintln(stdout, Version)
		return exitOK
	case "agent":
		return runAgent(args[1:], stdout, stderr)
	case "-h", "--help", "help":
		printUsage(stdout)
		return exitOK
	default:
		fmt.Fprintf(stderr, "unknown command: %s\n", args[0])
		printUsage(stderr)
		return exitUsage
	}
}

func printUsage(w io.Writer) {
	fmt.Fprintf(w, "usage: coda <command> [flags]\n\n")
	fmt.Fprintf(w, "commands:\n")
	fmt.Fprintf(w, "  version                          print the coda version\n")
	fmt.Fprintf(w, "  agent new <name> [--provider p]  create a new agent\n")
	fmt.Fprintf(w, "  agent ls                         list agents\n")
	fmt.Fprintf(w, "  agent start <name>               start an agent session\n")
	fmt.Fprintf(w, "  agent stop <name> [--reason r]   stop the active session for an agent\n")
}

func runAgent(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintf(stderr, "usage: coda agent <subcommand>\n")
		return exitUsage
	}
	switch args[0] {
	case "new":
		return agentNew(args[1:], stdout, stderr)
	case "ls":
		return agentLs(args[1:], stdout, stderr)
	case "start":
		return agentStart(args[1:], stdout, stderr)
	case "stop":
		return agentStop(args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown agent subcommand: %s\n", args[0])
		return exitUsage
	}
}

func openStore(ctx context.Context) (*sql.DB, *session.Store, error) {
	path, err := db.DefaultPath()
	if err != nil {
		return nil, nil, err
	}
	conn, err := db.Open(ctx, path)
	if err != nil {
		return nil, nil, err
	}
	if err := db.Migrate(ctx, conn); err != nil {
		_ = conn.Close()
		return nil, nil, fmt.Errorf("migrate: %w", err)
	}
	return conn, session.NewStore(conn), nil
}

func agentNew(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("agent new", flag.ContinueOnError)
	fs.SetOutput(stderr)
	provider := fs.String("provider", "", "provider name")
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() != 1 {
		fmt.Fprintf(stderr, "usage: coda agent new <name> [--provider <name>]\n")
		return exitUsage
	}
	name := fs.Arg(0)
	if err := session.ValidateAgentName(name); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	ctx := context.Background()
	conn, store, err := openStore(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	defer conn.Close()
	if err := store.CreateAgent(ctx, session.Agent{Name: name, Provider: *provider}); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	fmt.Fprintf(stdout, "created: %s\n", name)
	return exitOK
}

func agentLs(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("agent ls", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() != 0 {
		fmt.Fprintf(stderr, "usage: coda agent ls\n")
		return exitUsage
	}
	ctx := context.Background()
	conn, store, err := openStore(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	defer conn.Close()

	agents, err := store.ListAgents(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	fmt.Fprintln(stdout, "NAME\tPROVIDER\tSESSION\tSTATE")
	for _, a := range agents {
		sessID := "-"
		state := "-"
		sess, err := store.GetActiveSession(ctx, a.Name)
		if err != nil && !errors.Is(err, session.ErrNotFound) {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return exitUserErr
		}
		if sess != nil {
			sessID = sess.ID
			state = string(sess.State)
		}
		provider := a.Provider
		if provider == "" {
			provider = "-"
		}
		fmt.Fprintf(stdout, "%s\t%s\t%s\t%s\n", a.Name, provider, sessID, state)
	}
	return exitOK
}

func agentStart(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("agent start", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() != 1 {
		fmt.Fprintf(stderr, "usage: coda agent start <name>\n")
		return exitUsage
	}
	name := fs.Arg(0)
	ctx := context.Background()
	conn, store, err := openStore(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	defer conn.Close()

	return startAgent(ctx, store, defaultRegistry(), name, stdout, stderr)
}

func agentStop(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("agent stop", flag.ContinueOnError)
	fs.SetOutput(stderr)
	reason := fs.String("reason", "user", "stop reason recorded on the session")
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() != 1 {
		fmt.Fprintf(stderr, "usage: coda agent stop <name> [--reason <text>]\n")
		return exitUsage
	}
	name := fs.Arg(0)
	ctx := context.Background()
	conn, store, err := openStore(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	defer conn.Close()
	return stopAgent(ctx, store, defaultRegistry(), name, *reason, stdout, stderr)
}

// defaultRegistry returns the process-wide provider registry. Empty
// in this PR; later cards will populate it from plugins.
func defaultRegistry() *session.ProviderRegistry {
	return session.NewProviderRegistry()
}

func startAgent(ctx context.Context, store *session.Store, reg *session.ProviderRegistry, name string, stdout, stderr io.Writer) int {
	agent, err := store.GetAgent(ctx, name)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	provider, ok := reg.Get(agent.Provider)
	if !ok || agent.Provider == "" {
		fmt.Fprintf(stderr, "error: %v\n", &session.NoProviderError{AgentName: agent.Name, Provider: agent.Provider})
		return exitUserErr
	}
	sess := session.Session{
		ID:        session.NewSessionID(),
		AgentName: agent.Name,
		Provider:  agent.Provider,
		State:     session.StateCreated,
	}
	if err := store.CreateSession(ctx, sess); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	if _, err := provider.Start(*agent, session.ProviderConfig{}); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	if err := store.TransitionSession(ctx, sess.ID, session.StateCreated, session.StateStarted); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	fmt.Fprintf(stdout, "started: %s\n", sess.ID)
	return exitOK
}

func stopAgent(ctx context.Context, store *session.Store, reg *session.ProviderRegistry, name, reason string, stdout, stderr io.Writer) int {
	agent, err := store.GetAgent(ctx, name)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	sess, err := store.GetActiveSession(ctx, agent.Name)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	provider, ok := reg.Get(agent.Provider)
	if !ok || agent.Provider == "" {
		fmt.Fprintf(stderr, "error: %v\n", &session.NoProviderError{AgentName: agent.Name, Provider: agent.Provider})
		return exitUserErr
	}
	prev := sess.State
	if err := store.TransitionSession(ctx, sess.ID, prev, session.StateStopped, reason); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	if err := provider.Stop(sess.ID); err != nil {
		if rbErr := store.RollbackFromStopped(ctx, sess.ID, prev); rbErr != nil {
			fmt.Fprintf(stderr, "error: provider stop: %v; rollback: %v\n", err, rbErr)
			return exitUserErr
		}
		fmt.Fprintf(stderr, "error: provider stop: %v\n", err)
		return exitUserErr
	}
	fmt.Fprintf(stdout, "stopped: %s\n", sess.ID)
	return exitOK
}
