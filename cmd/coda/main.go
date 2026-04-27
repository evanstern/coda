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
	"github.com/evanstern/coda/internal/messages"
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
	fmt.Fprintf(w, "  send <from> <to> <type> <body>   route a message\n")
	fmt.Fprintf(w, "  recv <agent>                     list unacked messages for agent\n")
	fmt.Fprintf(w, "  ack <id>                         mark a message acknowledged\n")
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
	conn, store, msgStore, err := openStores(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	defer conn.Close()

	return startAgent(ctx, store, msgStore, defaultRegistry(), name, stdout, stderr)
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
	if _, err := provider.Start(*agent, session.ProviderConfig{}); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
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
	router := messages.NewRouter(msgStore, store, defaultRegistry())
	id, delivered, err := router.Send(ctx, from, to, t, []byte(body))
	if err != nil {
		if id == 0 {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return exitUserErr
		}
		fmt.Fprintf(stderr, "warn: %v\n", err)
	}
	fmt.Fprintf(stdout, "sent: id=%d delivered=%t\n", id, delivered)
	return exitOK
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
	conn, _, msgStore, err := openStores(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitUserErr
	}
	defer conn.Close()
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
