package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/evanstern/coda/internal/db"
	"github.com/evanstern/coda/internal/messages"
	"github.com/evanstern/coda/internal/session"
	_ "modernc.org/sqlite"
)

type stubProvider struct {
	startCalls int
	stopCalls  int
	stopSeen   []string
	startErr   error
	stopErr    error
}

func (s *stubProvider) Start(a session.Agent, _ session.ProviderConfig) (string, error) {
	s.startCalls++
	return "stub-" + a.Name, s.startErr
}
func (s *stubProvider) Stop(sessionID string) error {
	s.stopCalls++
	s.stopSeen = append(s.stopSeen, sessionID)
	return s.stopErr
}
func (s *stubProvider) Deliver(_ string, _ session.Message) (bool, error) {
	return true, nil
}
func (s *stubProvider) Health(_ string) (session.Status, error) {
	return session.Status{State: "running", Healthy: true}, nil
}
func (s *stubProvider) Output(_ string, _ *time.Time) ([]session.Message, error) {
	return nil, nil
}
func (s *stubProvider) Attach(_ string) error { return nil }

func newTestStore(t *testing.T) *session.Store {
	t.Helper()
	store, _ := newTestStores(t)
	return store
}

func newTestStores(t *testing.T) (*session.Store, *messages.Store) {
	t.Helper()
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared&_pragma=foreign_keys(1)", t.Name())
	d, err := sql.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	d.SetMaxOpenConns(1)
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return session.NewStore(d), messages.NewStore(d)
}

func TestAgentNewThenBoot(t *testing.T) {
	state := t.TempDir()
	config := t.TempDir()
	t.Setenv("XDG_STATE_HOME", state)
	t.Setenv("XDG_CONFIG_HOME", config)

	var stdout, stderr bytes.Buffer
	if code := agentNew([]string{"ash"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("agent new: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "created: ash") {
		t.Fatalf("unexpected new stdout: %q", stdout.String())
	}

	stdout.Reset()
	stderr.Reset()
	if code := agentBoot([]string{"ash"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("agent boot: code=%d stderr=%q", code, stderr.String())
	}
	var got struct {
		AgentName string            `json:"agent_name"`
		ConfigDir string            `json:"config_dir"`
		Files     []string          `json:"files"`
		EnvVars   map[string]string `json:"env_vars"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("decode boot json: %v\nraw: %s", err, stdout.String())
	}
	if got.AgentName != "ash" {
		t.Fatalf("agent_name=%q", got.AgentName)
	}
	if got.EnvVars["CODA_AGENT_NAME"] != "ash" {
		t.Fatalf("env_vars=%v", got.EnvVars)
	}
	if !strings.HasPrefix(got.ConfigDir, config) {
		t.Fatalf("config_dir %q not under %q", got.ConfigDir, config)
	}
	if len(got.Files) < 1 {
		t.Fatalf("expected at least one file, got %v", got.Files)
	}
}

func TestStartAgentNoProvider(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "lonely", Provider: ""}); err != nil {
		t.Fatal(err)
	}
	reg := session.NewProviderRegistry()
	var stdout, stderr bytes.Buffer
	code := startAgent(ctx, store, nil, reg, "lonely", &stdout, &stderr)
	if code != exitUserErr {
		t.Fatalf("expected exit %d, got %d (stderr=%q)", exitUserErr, code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "no provider registered for agent lonely") {
		t.Fatalf("unexpected error text: %q", stderr.String())
	}
}

func TestStartAgentUnregisteredProvider(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "ghost"}); err != nil {
		t.Fatal(err)
	}
	reg := session.NewProviderRegistry()
	var stdout, stderr bytes.Buffer
	code := startAgent(ctx, store, nil, reg, "a", &stdout, &stderr)
	if code != exitUserErr {
		t.Fatalf("expected exit %d, got %d", exitUserErr, code)
	}
	if !strings.Contains(stderr.String(), "agent.provider=ghost") {
		t.Fatalf("expected provider name in error, got %q", stderr.String())
	}
}

func TestStartStopAgentHappyPath(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	provider := &stubProvider{}
	reg := session.NewProviderRegistry()
	reg.Register("stub", provider)

	var stdout, stderr bytes.Buffer
	if code := startAgent(ctx, store, nil, reg, "a", &stdout, &stderr); code != exitOK {
		t.Fatalf("start: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.HasPrefix(stdout.String(), "started: ") {
		t.Fatalf("expected stdout to start with 'started: ', got %q", stdout.String())
	}
	if provider.startCalls != 1 {
		t.Fatalf("expected 1 start call, got %d", provider.startCalls)
	}

	active, err := store.GetActiveSession(ctx, "a")
	if err != nil {
		t.Fatal(err)
	}
	if active.State != session.StateStarted {
		t.Fatalf("expected started, got %s", active.State)
	}
	if active.ProviderSessionID != "stub-a" {
		t.Fatalf("expected ProviderSessionID=stub-a (returned by stubProvider.Start), got %q", active.ProviderSessionID)
	}

	stdout.Reset()
	stderr.Reset()
	if code := stopAgent(ctx, store, reg, "a", "done", &stdout, &stderr); code != exitOK {
		t.Fatalf("stop: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.HasPrefix(stdout.String(), "stopped: ") {
		t.Fatalf("expected stdout to start with 'stopped: ', got %q", stdout.String())
	}
	if provider.stopCalls != 1 {
		t.Fatalf("expected 1 stop call, got %d", provider.stopCalls)
	}
	if len(provider.stopSeen) != 1 || provider.stopSeen[0] != "stub-a" {
		t.Fatalf("expected Stop called with provider session id 'stub-a', got %v", provider.stopSeen)
	}
	stopped, err := store.GetSession(ctx, active.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stopped.State != session.StateStopped || stopped.StopReason != "done" {
		t.Fatalf("unexpected stopped session: %+v", stopped)
	}
}

func TestSendRecvAck_EndToEnd(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())

	var stdout, stderr bytes.Buffer
	if code := run([]string{"agent", "new", "ash"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("agent new ash: code=%d stderr=%q", code, stderr.String())
	}
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"agent", "new", "zach"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("agent new zach: code=%d stderr=%q", code, stderr.String())
	}

	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"send", "ash", "zach", "note", `{"text":"hello"}`}, &stdout, &stderr); code != exitOK {
		t.Fatalf("send: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "sent: id=1 delivered=false") {
		t.Fatalf("unexpected send stdout: %q", stdout.String())
	}

	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"recv", "zach"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("recv: code=%d stderr=%q", code, stderr.String())
	}
	out := stdout.String()
	if !strings.Contains(out, "ID") || !strings.Contains(out, `{"text":"hello"}`) {
		t.Fatalf("recv missing row: %q", out)
	}

	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"ack", "1"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("ack: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "acked: 1") {
		t.Fatalf("unexpected ack stdout: %q", stdout.String())
	}

	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"recv", "zach"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("recv after ack: code=%d", code)
	}
	post := stdout.String()
	if strings.Contains(post, `{"text":"hello"}`) {
		t.Fatalf("expected no rows after ack, got %q", post)
	}
}

func TestSend_InvalidBodyAndType(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())

	var stdout, stderr bytes.Buffer
	if code := run([]string{"agent", "new", "ash"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("agent new: %d %q", code, stderr.String())
	}
	if code := run([]string{"agent", "new", "zach"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("agent new: %d %q", code, stderr.String())
	}
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"send", "ash", "zach", "note", "not-json"}, &stdout, &stderr); code != exitUserErr {
		t.Fatalf("expected exitUserErr for bad json, got %d", code)
	}
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"send", "ash", "zach", "bogus", `{}`}, &stdout, &stderr); code != exitUserErr {
		t.Fatalf("expected exitUserErr for bad type, got %d", code)
	}
}

func TestStopAgentRollsBackWhenProviderStopFails(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "a", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	provider := &stubProvider{stopErr: errors.New("boom")}
	reg := session.NewProviderRegistry()
	reg.Register("stub", provider)

	var stdout, stderr bytes.Buffer
	if code := startAgent(ctx, store, nil, reg, "a", &stdout, &stderr); code != exitOK {
		t.Fatalf("start: code=%d stderr=%q", code, stderr.String())
	}
	active, err := store.GetActiveSession(ctx, "a")
	if err != nil {
		t.Fatal(err)
	}
	priorState := active.State

	stdout.Reset()
	stderr.Reset()
	code := stopAgent(ctx, store, reg, "a", "done", &stdout, &stderr)
	if code != exitUserErr {
		t.Fatalf("expected exit %d, got %d (stderr=%q)", exitUserErr, code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "provider stop:") {
		t.Fatalf("expected provider stop error in stderr, got %q", stderr.String())
	}
	if provider.stopCalls != 1 {
		t.Fatalf("expected 1 stop call, got %d", provider.stopCalls)
	}

	got, err := store.GetSession(ctx, active.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != priorState {
		t.Fatalf("expected rollback to %s, got %s", priorState, got.State)
	}
	if got.StoppedAt != nil {
		t.Fatalf("expected stopped_at cleared after rollback, got %v", got.StoppedAt)
	}
	if got.StopReason != "" {
		t.Fatalf("expected stop_reason cleared after rollback, got %q", got.StopReason)
	}
}

func TestSend_ExitCodeOnTransportError(t *testing.T) {
	store, msgStore := newTestStores(t)
	ctx := context.Background()
	if err := store.CreateAgent(ctx, session.Agent{Name: "ash", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	if err := store.CreateAgent(ctx, session.Agent{Name: "zach", Provider: "stub"}); err != nil {
		t.Fatal(err)
	}
	sess := session.Session{
		ID:        session.NewSessionID(),
		AgentName: "zach",
		Provider:  "stub",
		State:     session.StateCreated,
	}
	if err := store.CreateSession(ctx, sess); err != nil {
		t.Fatal(err)
	}
	if err := store.TransitionSession(ctx, sess.ID, session.StateCreated, session.StateStarted); err != nil {
		t.Fatal(err)
	}
	reg := session.NewProviderRegistry()
	reg.Register("stub", &failingProvider{})
	router := messages.NewRouter(msgStore, store, reg)
	id, delivered, err := router.Send(ctx, "ash", "zach", messages.TypeNote, []byte(`{}`))
	if err == nil {
		t.Fatalf("expected error from failing transport")
	}
	if id == 0 {
		t.Fatalf("expected message persisted before failure")
	}
	if delivered {
		t.Fatalf("expected delivered=false")
	}
	exit := sendExitCode(id, err)
	if exit != exitUserErr {
		t.Fatalf("expected exit %d on transport error, got %d", exitUserErr, exit)
	}
	if got := sendExitCode(0, errors.New("validation")); got != exitUserErr {
		t.Fatalf("expected exit %d on pre-insert error, got %d", exitUserErr, got)
	}
	if got := sendExitCode(42, nil); got != exitOK {
		t.Fatalf("expected exit %d on success, got %d", exitOK, got)
	}
}

type failingProvider struct{ stubProvider }

func (f *failingProvider) Deliver(_ string, _ session.Message) (bool, error) {
	return false, errors.New("transport boom")
}

func TestRecv_UnknownAgent(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())
	var stdout, stderr bytes.Buffer
	if code := run([]string{"recv", "ghost"}, &stdout, &stderr); code != exitUserErr {
		t.Fatalf("expected exitUserErr for unknown agent, got %d (stderr=%q)", code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "unknown agent") {
		t.Fatalf("expected unknown-agent error, got %q", stderr.String())
	}
}

func TestRecv_JSONBodyNotBase64(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())

	var stdout, stderr bytes.Buffer
	if code := run([]string{"agent", "new", "ash"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("new ash: %d %q", code, stderr.String())
	}
	if code := run([]string{"agent", "new", "zach"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("new zach: %d %q", code, stderr.String())
	}
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"send", "ash", "zach", "note", `{"text":"hello"}`}, &stdout, &stderr); code != exitOK {
		t.Fatalf("send: %d %q", code, stderr.String())
	}
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"recv", "--json", "zach"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("recv --json: %d %q", code, stderr.String())
	}
	var rows []struct {
		ID   int64           `json:"id"`
		Body json.RawMessage `json:"body"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &rows); err != nil {
		t.Fatalf("decode recv json: %v\nraw: %s", err, stdout.String())
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	var body struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(rows[0].Body, &body); err != nil {
		t.Fatalf("body should be embedded JSON not base64: %v\nraw: %s", err, rows[0].Body)
	}
	if body.Text != "hello" {
		t.Fatalf("body.text=%q want %q", body.Text, "hello")
	}
}

func makeFeatureTestProject(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	bare := filepath.Join(root, ".bare")
	gitMust(t, root, "init", "--bare", "--initial-branch=main", ".bare")
	if err := os.WriteFile(filepath.Join(root, ".git"), []byte("gitdir: ./.bare\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitMust(t, bare, "symbolic-ref", "HEAD", "refs/heads/main")
	gitMust(t, root, "worktree", "add", filepath.Join(root, "main"))
	mainWT := filepath.Join(root, "main")
	gitMust(t, mainWT, "config", "user.email", "test@example.com")
	gitMust(t, mainWT, "config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(mainWT, "README.md"), []byte("# test\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitMust(t, mainWT, "add", "README.md")
	gitMust(t, mainWT, "commit", "-m", "init")
	return root
}

func gitMust(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func TestFeature_StartLsFinish_RoundTrip(t *testing.T) {
	root := makeFeatureTestProject(t)
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })
	if err := os.Chdir(filepath.Join(root, "main")); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	if code := run([]string{"feature", "start", "feat-x"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("feature start: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "created: feat-x at ") {
		t.Fatalf("unexpected start stdout: %q", stdout.String())
	}
	if _, err := os.Stat(filepath.Join(root, "feat-x")); err != nil {
		t.Fatalf("worktree not created: %v", err)
	}

	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"feature", "ls"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("feature ls: code=%d stderr=%q", code, stderr.String())
	}
	out := stdout.String()
	if !strings.Contains(out, "feat-x") {
		t.Fatalf("ls missing feat-x: %q", out)
	}
	if strings.Contains(out, " main ") || strings.Contains(out, "\tmain\t") {
		t.Fatalf("ls should exclude main worktree: %q", out)
	}

	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"feature", "finish", "feat-x"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("feature finish: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "removed: feat-x") {
		t.Fatalf("unexpected finish stdout: %q", stdout.String())
	}
	if _, err := os.Stat(filepath.Join(root, "feat-x")); !os.IsNotExist(err) {
		t.Fatalf("worktree path still exists: %v", err)
	}
}

func TestMCP_ServeRoundTrip(t *testing.T) {
	pluginsDir := t.TempDir()
	pluginRoot := filepath.Join(pluginsDir, "demo")
	if err := os.MkdirAll(filepath.Join(pluginRoot, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	manifest := `{
  "name": "demo",
  "version": "0.1.0",
  "coda": "^0.1.0",
  "provides": {
    "mcp_tools": {
      "echo": {"description": "echo back stdin", "command": ["bin/echo"]}
    }
  }
}`
	if err := os.WriteFile(filepath.Join(pluginRoot, "plugin.json"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginRoot, "bin", "echo"), []byte("#!/bin/sh\ncat\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CODA_PLUGINS_DIR", pluginsDir)

	stdinPipeR, stdinPipeW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	prevStdin := os.Stdin
	os.Stdin = stdinPipeR
	t.Cleanup(func() { os.Stdin = prevStdin })

	go func() {
		_, _ = stdinPipeW.WriteString(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}` + "\n")
		_ = stdinPipeW.Close()
	}()

	var stdout, stderr bytes.Buffer
	if code := run([]string{"mcp", "serve"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("mcp serve: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), `"echo"`) {
		t.Fatalf("expected echo tool in stdout: %q", stdout.String())
	}
	var resp struct {
		Result struct {
			Tools []struct {
				Name string `json:"name"`
			} `json:"tools"`
		} `json:"result"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v\n%s", err, stdout.String())
	}
	if len(resp.Result.Tools) != 1 || resp.Result.Tools[0].Name != "echo" {
		t.Fatalf("tools=%+v", resp.Result.Tools)
	}
}

func TestMCP_ToolsCommand(t *testing.T) {
	pluginsDir := t.TempDir()
	pluginRoot := filepath.Join(pluginsDir, "demo")
	if err := os.MkdirAll(pluginRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	manifest := `{"name":"demo","version":"0.1.0","coda":"^0.1.0","provides":{"mcp_tools":{"echo":{"description":"e","command":["true"]}}}}`
	if err := os.WriteFile(filepath.Join(pluginRoot, "plugin.json"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CODA_PLUGINS_DIR", pluginsDir)

	var stdout, stderr bytes.Buffer
	if code := run([]string{"mcp", "tools"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("mcp tools: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "echo") || !strings.Contains(stdout.String(), "demo") {
		t.Fatalf("missing tool/plugin: %q", stdout.String())
	}
}

func TestFeature_FinishUncommittedNoForce(t *testing.T) {
	root := makeFeatureTestProject(t)
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })
	if err := os.Chdir(filepath.Join(root, "main")); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	if code := run([]string{"feature", "start", "dirty"}, &stdout, &stderr); code != exitOK {
		t.Fatalf("start: %d %q", code, stderr.String())
	}
	if err := os.WriteFile(filepath.Join(root, "dirty", "scratch.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"feature", "finish", "dirty"}, &stdout, &stderr); code != exitUserErr {
		t.Fatalf("expected exitUserErr, got %d", code)
	}
	if !strings.Contains(stderr.String(), "uncommitted") {
		t.Fatalf("expected uncommitted error: %q", stderr.String())
	}
}
