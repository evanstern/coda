package plugin

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/evanstern/coda/internal/session"
)

func writeScript(t *testing.T, dir, name, body string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell-script fixtures unsupported on windows")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	script := "#!/bin/sh\n" + body
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

const providerScriptBody = `set -e
sub=$1
shift
case "$sub" in
  start)
    cat > "$LOG_DIR/start.in"
    printf '%s\n' "$@" > "$LOG_DIR/start.args"
    echo "sess-${LOG_TAG}"
    ;;
  stop)
    printf '%s\n' "$@" > "$LOG_DIR/stop.args"
    ;;
  deliver)
    cat > "$LOG_DIR/deliver.in"
    printf '%s\n' "$@" > "$LOG_DIR/deliver.args"
    printf '{"delivered":true}\n'
    ;;
  health)
    printf '%s\n' "$@" > "$LOG_DIR/health.args"
    printf '{"state":"running","healthy":true,"detail":"ok"}\n'
    ;;
  output)
    printf '%s\n' "$@" > "$LOG_DIR/output.args"
    printf '[{"ID":"m1","From":"x","To":"y","Type":"note","Body":"aGk=","CreatedAt":"2025-01-01T00:00:00Z"}]\n'
    ;;
  attach)
    printf '%s\n' "$@" > "$LOG_DIR/attach.args"
    ;;
  fail)
    echo "boom" >&2
    exit 7
    ;;
esac
`

func newProviderFixture(t *testing.T, tag string) (*SubprocessProvider, string) {
	root := t.TempDir()
	logDir := t.TempDir()
	bin := writeScript(t, filepath.Join(root, "bin"), "provider", providerScriptBody)
	t.Setenv("LOG_DIR", logDir)
	t.Setenv("LOG_TAG", tag)
	p := NewSubprocessProvider("demo", root, bin)
	return p, logDir
}

func TestSubprocessProvider_Start(t *testing.T) {
	p, logDir := newProviderFixture(t, "start")
	id, err := p.Start(session.Agent{Name: "ash"}, session.ProviderConfig{"foo": "bar"})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if id != "sess-start" {
		t.Fatalf("session id=%q", id)
	}
	args, _ := os.ReadFile(filepath.Join(logDir, "start.args"))
	if !strings.Contains(string(args), "--agent=ash") {
		t.Fatalf("args=%q", args)
	}
	in, _ := os.ReadFile(filepath.Join(logDir, "start.in"))
	if !strings.Contains(string(in), `"foo":"bar"`) {
		t.Fatalf("stdin=%q", in)
	}
}

func TestSubprocessProvider_Stop(t *testing.T) {
	p, logDir := newProviderFixture(t, "stop")
	if err := p.Stop("sess-1"); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	args, _ := os.ReadFile(filepath.Join(logDir, "stop.args"))
	if strings.TrimSpace(string(args)) != "sess-1" {
		t.Fatalf("args=%q", args)
	}
}

func TestSubprocessProvider_Deliver(t *testing.T) {
	p, logDir := newProviderFixture(t, "del")
	delivered, err := p.Deliver("sess-1", session.Message{ID: "m1"})
	if err != nil {
		t.Fatalf("Deliver: %v", err)
	}
	if !delivered {
		t.Fatalf("expected delivered=true")
	}
	in, _ := os.ReadFile(filepath.Join(logDir, "deliver.in"))
	if !strings.Contains(string(in), `"ID":"m1"`) {
		t.Fatalf("stdin=%q", in)
	}
}

func TestSubprocessProvider_Health(t *testing.T) {
	p, _ := newProviderFixture(t, "health")
	s, err := p.Health("sess-1")
	if err != nil {
		t.Fatalf("Health: %v", err)
	}
	if s.State != "running" || !s.Healthy || s.Detail != "ok" {
		t.Fatalf("status=%+v", s)
	}
}

func TestSubprocessProvider_Output(t *testing.T) {
	p, logDir := newProviderFixture(t, "output")
	since := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	msgs, err := p.Output("sess-1", &since)
	if err != nil {
		t.Fatalf("Output: %v", err)
	}
	if len(msgs) != 1 || msgs[0].ID != "m1" {
		t.Fatalf("msgs=%+v", msgs)
	}
	args, _ := os.ReadFile(filepath.Join(logDir, "output.args"))
	if !strings.Contains(string(args), "--since=2025-01-01T00:00:00Z") {
		t.Fatalf("args=%q", args)
	}
}

func TestSubprocessProvider_Attach(t *testing.T) {
	p, _ := newProviderFixture(t, "attach")
	if err := p.Attach("sess-1"); err != nil {
		t.Fatalf("Attach: %v", err)
	}
}

func TestSubprocessProvider_NonZeroExit(t *testing.T) {
	root := t.TempDir()
	bin := writeScript(t, filepath.Join(root, "bin"), "provider", "exit 7\n")
	p := NewSubprocessProvider("demo", root, bin)
	if err := p.Stop("sess-x"); err == nil {
		t.Fatalf("expected error on non-zero exit")
	}
}
