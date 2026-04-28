// Package main is the entrypoint for the coda CLI.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/evanstern/coda/internal/db"
	"github.com/evanstern/coda/internal/feature"
	"github.com/evanstern/coda/internal/identity"
	"github.com/evanstern/coda/internal/messages"
	"github.com/evanstern/coda/internal/plugin"
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
	case "send":
		return runSend(args[1:], stdout, stderr)
	case "recv":
		return runRecv(args[1:], stdout, stderr)
	case "ack":
		return runAck(args[1:], stdout, stderr)
	case "feature":
		return runFeature(args[1:], stdout, stderr)
	case "mcp":
		return runMCP(args[1:], stdout, stderr)
	case "-h", "--help", "help":
		printUsage(stdout)
		return exitOK
	default:
		return runPluginCommand(args, stdout, stderr)
	}
}

func runPluginCommand(args []string, stdout, stderr io.Writer) int {
	plugins, err := plugin.NewLoader("", stderr).Load(context.Background())
	if err != nil {
		fmt.Fprintf(stderr, "warn: load plugins: %v\n", err)
	}
	registry, err := plugin.BuildCommandRegistry(plugins)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	if _, ok := registry.Lookup(args[0]); ok {
		return registry.Dispatch(context.Background(), args[0], args[1:], os.Stdin, stdout, stderr)
	}
	fmt.Fprintf(stderr, "unknown command: %s\n", args[0])
	printUsage(stderr)
	return exitUsage
}

func runMCP(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintf(stderr, "usage: coda mcp <serve|tools>\n")
		return exitUsage
	}
	switch args[0] {
	case "serve":
		return mcpServe(args[1:], stdout, stderr)
	case "tools":
		return mcpTools(args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown mcp subcommand: %s\n", args[0])
		return exitUsage
	}
}

func loadMCPServer(stderr io.Writer) (*plugin.MCPServer, error) {
	plugins, err := plugin.NewLoader("", stderr).Load(context.Background())
	if err != nil {
		return nil, err
	}
	return plugin.NewMCPServer(plugins)
}

func mcpServe(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("mcp serve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() != 0 {
		fmt.Fprintf(stderr, "usage: coda mcp serve\n")
		return exitUsage
	}
	srv, err := loadMCPServer(stderr)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	if err := srv.Serve(context.Background(), os.Stdin, stdout); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	return exitOK
}

func mcpTools(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("mcp tools", flag.ContinueOnError)
	fs.SetOutput(stderr)
	asJSON := fs.Bool("json", false, "emit JSON instead of table")
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	srv, err := loadMCPServer(stderr)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	if *asJSON {
		out, err := json.MarshalIndent(srv.Tools, "", "  ")
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return exitUserErr
		}
		fmt.Fprintln(stdout, string(out))
		return exitOK
	}
	tw := tabwriter.NewWriter(stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "NAME\tPLUGIN\tDESCRIPTION")
	for _, t := range srv.Tools {
		fmt.Fprintf(tw, "%s\t%s\t%s\n", t.Name, t.Plugin, t.Description)
	}
	if err := tw.Flush(); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	return exitOK
}

func printUsage(w io.Writer) {
	fmt.Fprintf(w, "usage: coda <command> [flags]\n\n")
	fmt.Fprintf(w, "commands:\n")
	fmt.Fprintf(w, "  version                          print the coda version\n")
	fmt.Fprintf(w, "  agent new <name> [--provider p]  create a new agent\n")
	fmt.Fprintf(w, "  agent ls                         list agents\n")
	fmt.Fprintf(w, "  agent boot <name>                load identity for a provider\n")
	fmt.Fprintf(w, "  agent start <name>               start an agent session\n")
	fmt.Fprintf(w, "  agent stop <name> [--reason r]   stop the active session for an agent\n")
	fmt.Fprintf(w, "  send <from> <to> <type> <body>   route a message\n")
	fmt.Fprintf(w, "  recv <agent>                     list unacked messages for agent\n")
	fmt.Fprintf(w, "  ack <id>                         mark a message acknowledged\n")
	fmt.Fprintf(w, "  feature start <branch>           create a worktree from the default or given base branch\n")
	fmt.Fprintf(w, "  feature finish <branch>          remove a worktree and delete its branch\n")
	fmt.Fprintf(w, "  feature ls                       list active feature worktrees\n")
	fmt.Fprintf(w, "  mcp serve                        run the stdio MCP server (plugin tools)\n")
	fmt.Fprintf(w, "  mcp tools                        list registered MCP tools\n")
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
	case "boot":
		return agentBoot(args[1:], stdout, stderr)
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
	conn, err := openDB(ctx)
	if err != nil {
		return nil, nil, err
	}
	return conn, session.NewStore(conn), nil
}

func openStores(ctx context.Context) (*sql.DB, *session.Store, *messages.Store, error) {
	conn, err := openDB(ctx)
	if err != nil {
		return nil, nil, nil, err
	}
	return conn, session.NewStore(conn), messages.NewStore(conn), nil
}

func openDB(ctx context.Context) (*sql.DB, error) {
	path, err := db.DefaultPath()
	if err != nil {
		return nil, err
	}
	conn, err := db.Open(ctx, path)
	if err != nil {
		return nil, err
	}
	if err := db.Migrate(ctx, conn); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return conn, nil
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
	root, err := identity.DefaultRoot()
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	layout := identity.Resolve(root, name)
	if err := identity.Scaffold(layout); err != nil {
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
	if err := store.CreateAgent(ctx, session.Agent{Name: name, Provider: *provider, ConfigDir: layout.Root}); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	fmt.Fprintf(stdout, "created: %s\n", name)
	return exitOK
}

func agentBoot(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("agent boot", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() != 1 {
		fmt.Fprintf(stderr, "usage: coda agent boot <name>\n")
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
	agent, err := store.GetAgent(ctx, name)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	if agent.ConfigDir == "" {
		fmt.Fprintf(stderr, "error: agent %q has no config_dir; run \"coda agent new %s\" to scaffold or set it manually\n", name, name)
		return exitUserErr
	}
	layout := identity.LayoutAt(agent.ConfigDir)
	payload, err := identity.Boot(agent.Name, layout)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	out, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	fmt.Fprintln(stdout, string(out))
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
	conn, store, msgStore, err := openStores(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	defer conn.Close()

	return startAgent(ctx, store, msgStore, defaultRegistry(ctx), name, stdout, stderr)
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
	return stopAgent(ctx, store, defaultRegistry(ctx), name, *reason, stdout, stderr)
}

// defaultRegistry returns the process-wide provider registry,
// populated from plugins discovered under the default plugins
// directory. Each registered SubprocessProvider is bound to ctx so
// CLI cancellation propagates to plugin subprocesses. Failures
// during plugin load are written to stderr but never abort startup;
// an empty registry is still useful (the user just gets "no
// provider registered" at agent start time).
func defaultRegistry(ctx context.Context) *session.ProviderRegistry {
	reg := session.NewProviderRegistry()
	plugins, err := plugin.NewLoader("", os.Stderr).Load(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "warn: load plugins: %v\n", err)
		return reg
	}
	for _, pl := range plugins {
		for name, spec := range pl.Manifest.Provides.Providers {
			p := plugin.NewSubprocessProvider(name, pl.Root, spec.Exec).WithContext(ctx)
			reg.Register(name, p)
		}
	}
	return reg
}

// loadPluginsForHooks loads plugins for hook dispatch. Errors warn to
// stderr; a partial set is still useful.
func loadPluginsForHooks(ctx context.Context, stderr io.Writer) []plugin.Plugin {
	plugins, err := plugin.NewLoader("", stderr).Load(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "warn: load plugins: %v\n", err)
		return nil
	}
	return plugins
}

func startAgent(ctx context.Context, store *session.Store, msgStore *messages.Store, reg *session.ProviderRegistry, name string, stdout, stderr io.Writer) int {
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
	provSessID, err := provider.Start(*agent, session.ProviderConfig{})
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	if provSessID != "" {
		if setErr := store.SetProviderSessionID(ctx, sess.ID, provSessID); setErr != nil {
			// Best-effort cleanup: the provider session is running
			// but we can't address it on a future Stop call (we'd
			// fall back to coda's ULID, which is the bug this
			// migration exists to prevent). Stop the orphan and
			// mark the session row stopped so subsequent commands
			// see consistent state.
			cleanupErr := provider.Stop(provSessID)
			if cleanupErr == nil {
				if transErr := store.TransitionSession(ctx, sess.ID, session.StateCreated, session.StateStopped, "provider-id-record-failed"); transErr != nil {
					cleanupErr = transErr
				}
			}
			if cleanupErr != nil {
				fmt.Fprintf(stderr, "error: provider started but recording its session id failed: %v; cleanup failed: %v\n", setErr, cleanupErr)
				return exitUserErr
			}
			fmt.Fprintf(stderr, "error: provider started but recording its session id failed: %v; provider session %q was stopped\n", setErr, provSessID)
			return exitUserErr
		}
		sess.ProviderSessionID = provSessID
	}
	if err := store.TransitionSession(ctx, sess.ID, session.StateCreated, session.StateStarted); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	if msgStore != nil {
		router := messages.NewRouter(msgStore, store, reg)
		if n, err := router.Drain(ctx, agent.Name); err != nil {
			fmt.Fprintf(stderr, "warn: drain: %v (delivered=%d)\n", err, n)
		}
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
	if err := provider.Stop(sess.ProviderID()); err != nil {
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

func runSend(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("send", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() != 4 {
		fmt.Fprintf(stderr, "usage: coda send <from> <to> <type> <body>\n")
		return exitUsage
	}
	from, to, typeStr, body := fs.Arg(0), fs.Arg(1), fs.Arg(2), fs.Arg(3)
	if !json.Valid([]byte(body)) {
		fmt.Fprintf(stderr, "error: body is not valid JSON\n")
		return exitUserErr
	}
	t := messages.MessageType(typeStr)
	if err := messages.ValidateType(t); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	ctx := context.Background()
	conn, store, msgStore, err := openStores(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	defer conn.Close()
	router := messages.NewRouter(msgStore, store, defaultRegistry(ctx))
	id, delivered, err := router.Send(ctx, from, to, t, []byte(body))
	if err != nil {
		if id == 0 {
			fmt.Fprintf(stderr, "error: %v\n", err)
		} else {
			fmt.Fprintf(stderr, "error: id=%d: %v\n", id, err)
		}
		return sendExitCode(id, err)
	}
	fmt.Fprintf(stdout, "sent: id=%d delivered=%t\n", id, delivered)
	return sendExitCode(id, nil)
}

// sendExitCode maps Router.Send results to a CLI exit code.
//   - nil err: success.
//   - err with id == 0: pre-insert failure (validation, unknown agent).
//   - err with id != 0: row persisted but transport failed; non-zero exit.
//
// The "no active session" case returns nil err with id != 0 inside
// Router.Send (drain handles it later) and maps to exitOK here.
func sendExitCode(id int64, err error) int {
	if err == nil {
		return exitOK
	}
	_ = id
	return exitUserErr
}

func runRecv(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("recv", flag.ContinueOnError)
	fs.SetOutput(stderr)
	asJSON := fs.Bool("json", false, "emit JSON array instead of table")
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() != 1 {
		fmt.Fprintf(stderr, "usage: coda recv <agent> [--json]\n")
		return exitUsage
	}
	name := fs.Arg(0)
	ctx := context.Background()
	conn, sessStore, msgStore, err := openStores(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	defer conn.Close()
	if _, err := sessStore.GetAgent(ctx, name); err != nil {
		if errors.Is(err, session.ErrNotFound) {
			fmt.Fprintf(stderr, "error: unknown agent %q\n", name)
			return exitUserErr
		}
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	rows, err := msgStore.ListUnacked(ctx, name)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	if *asJSON {
		out, err := json.Marshal(toJSONRows(rows))
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return exitUserErr
		}
		fmt.Fprintln(stdout, string(out))
		return exitOK
	}
	tw := tabwriter.NewWriter(stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tFROM\tTYPE\tCREATED\tDELIVERED\tACKED\tBODY-PREVIEW")
	for _, m := range rows {
		fmt.Fprintf(tw, "%d\t%s\t%s\t%s\t%s\t%s\t%s\n",
			m.ID, m.Sender, m.Type,
			m.CreatedAt.Format("2006-01-02 15:04:05"),
			yesNo(m.DeliveredAt != nil), yesNo(m.AckedAt != nil),
			bodyPreview(m.Body))
	}
	if err := tw.Flush(); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	return exitOK
}

func runAck(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("ack", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() != 1 {
		fmt.Fprintf(stderr, "usage: coda ack <id>\n")
		return exitUsage
	}
	id, err := strconv.ParseInt(fs.Arg(0), 10, 64)
	if err != nil {
		fmt.Fprintf(stderr, "error: invalid id: %v\n", err)
		return exitUserErr
	}
	ctx := context.Background()
	conn, _, msgStore, err := openStores(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	defer conn.Close()
	if err := msgStore.MarkAcked(ctx, id); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	fmt.Fprintf(stdout, "acked: %d\n", id)
	return exitOK
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

type recvJSONRow struct {
	ID          int64           `json:"id"`
	Sender      string          `json:"sender"`
	Recipient   string          `json:"recipient"`
	Type        string          `json:"type"`
	Body        json.RawMessage `json:"body"`
	CreatedAt   time.Time       `json:"created_at"`
	DeliveredAt *time.Time      `json:"delivered_at,omitempty"`
	AckedAt     *time.Time      `json:"acked_at,omitempty"`
}

func toJSONRows(rows []messages.Stored) []recvJSONRow {
	out := make([]recvJSONRow, len(rows))
	for i, m := range rows {
		body := json.RawMessage(m.Body)
		if !json.Valid(body) {
			b, _ := json.Marshal(string(m.Body))
			body = b
		}
		out[i] = recvJSONRow{
			ID:          m.ID,
			Sender:      m.Sender,
			Recipient:   m.Recipient,
			Type:        string(m.Type),
			Body:        body,
			CreatedAt:   m.CreatedAt,
			DeliveredAt: m.DeliveredAt,
			AckedAt:     m.AckedAt,
		}
	}
	return out
}

func bodyPreview(body []byte) string {
	const maxLen = 60
	s := strings.ReplaceAll(string(body), "\n", `\n`)
	s = strings.TrimRight(s, " \t")
	if len(s) > maxLen {
		s = s[:maxLen]
	}
	return s
}

func runFeature(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintf(stderr, "usage: coda feature <subcommand>\n")
		return exitUsage
	}
	switch args[0] {
	case "start":
		return featureStart(args[1:], stdout, stderr)
	case "finish":
		return featureFinish(args[1:], stdout, stderr)
	case "ls":
		return featureLs(args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown feature subcommand: %s\n", args[0])
		return exitUsage
	}
}

func featureStart(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("feature start", flag.ContinueOnError)
	fs.SetOutput(stderr)
	base := fs.String("base", "", "base branch to fork from (default: detect)")
	project := fs.String("project", "", "project name (default: detect from cwd)")
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() != 1 {
		fmt.Fprintf(stderr, "usage: coda feature start <branch> [--base <branch>] [--project <name>]\n")
		return exitUsage
	}
	branch := fs.Arg(0)
	proj, err := resolveFeatureProject(*project)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	ctx := context.Background()
	runner := plugin.NewHookRunner("", loadPluginsForHooks(ctx, stderr), stderr)
	wt, err := feature.Start(ctx, proj, branch, *base, runner)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	fmt.Fprintf(stdout, "created: %s at %s\n", wt.Branch, wt.Path)
	return exitOK
}

func featureFinish(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("feature finish", flag.ContinueOnError)
	fs.SetOutput(stderr)
	project := fs.String("project", "", "project name (default: detect from cwd)")
	force := fs.Bool("force", false, "discard uncommitted changes")
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() != 1 {
		fmt.Fprintf(stderr, "usage: coda feature finish <branch> [--project <name>] [--force]\n")
		return exitUsage
	}
	branch := fs.Arg(0)
	proj, err := resolveFeatureProject(*project)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	ctx := context.Background()
	runner := plugin.NewHookRunner("", loadPluginsForHooks(ctx, stderr), stderr)
	if err := feature.Finish(ctx, proj, branch, *force, runner); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	fmt.Fprintf(stdout, "removed: %s\n", branch)
	return exitOK
}

func featureLs(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("feature ls", flag.ContinueOnError)
	fs.SetOutput(stderr)
	project := fs.String("project", "", "project name (default: detect from cwd)")
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() != 0 {
		fmt.Fprintf(stderr, "usage: coda feature ls [--project <name>]\n")
		return exitUsage
	}
	proj, err := resolveFeatureProject(*project)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	wts, err := feature.List(context.Background(), proj)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	tw := tabwriter.NewWriter(stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "BRANCH\tPATH")
	for _, w := range wts {
		fmt.Fprintf(tw, "%s\t%s\n", w.Branch, w.Path)
	}
	if err := tw.Flush(); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	return exitOK
}

func resolveFeatureProject(name string) (*feature.Project, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return nil, fmt.Errorf("getwd: %w", err)
	}
	return feature.FindProject(cwd, name)
}
