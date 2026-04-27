package plugin

import (
	"bytes"
	"strings"
	"testing"
)

func TestParse_Valid(t *testing.T) {
	data := []byte(`{
  "name": "demo",
  "version": "0.1.0",
  "coda": "^0.1.0",
  "description": "demo plugin",
  "provides": {
    "commands": {"hello": {"description": "say hi", "exec": "bin/hello"}},
    "providers": {"demo": {"exec": "bin/provider"}},
    "hooks": {"pre-feature-create": ["hooks/pre/*"]},
    "mcp_tools": {"echo": {"description": "echo back", "command": ["bin/echo"]}}
  }
}`)
	m, err := Parse(data, nil)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if m.Name != "demo" || m.Version != "0.1.0" || m.Coda != "^0.1.0" {
		t.Fatalf("required fields: %+v", m)
	}
	if got := m.Provides.Commands["hello"].Exec; got != "bin/hello" {
		t.Fatalf("commands.hello.exec=%q", got)
	}
	if got := m.Provides.Providers["demo"].Exec; got != "bin/provider" {
		t.Fatalf("providers.demo.exec=%q", got)
	}
	if got := m.Provides.MCPTools["echo"].Command; len(got) != 1 || got[0] != "bin/echo" {
		t.Fatalf("mcp_tools.echo.command=%v", got)
	}
	if hooks := m.Provides.Hooks["pre-feature-create"]; len(hooks) != 1 {
		t.Fatalf("hooks=%v", hooks)
	}
}

func TestParse_MissingRequired(t *testing.T) {
	cases := []struct {
		name string
		json string
		miss string
	}{
		{"no name", `{"version":"0.1.0","coda":"^0.1.0"}`, `"name"`},
		{"no version", `{"name":"x","coda":"^0.1.0"}`, `"version"`},
		{"no coda", `{"name":"x","version":"0.1.0"}`, `"coda"`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := Parse([]byte(c.json), nil)
			if err == nil {
				t.Fatalf("expected error for %s", c.name)
			}
			if !strings.Contains(err.Error(), c.miss) {
				t.Fatalf("expected error to mention %s, got %v", c.miss, err)
			}
		})
	}
}

func TestParse_UnknownKeyWarns(t *testing.T) {
	data := []byte(`{"name":"x","version":"0.1.0","coda":"^0.1.0","weirdo":1}`)
	var warn bytes.Buffer
	m, err := Parse(data, &warn)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if !strings.Contains(warn.String(), `unknown manifest key "weirdo"`) {
		t.Fatalf("warn missing: %q", warn.String())
	}
	found := false
	for _, k := range m.Unknown {
		if k == "weirdo" {
			found = true
		}
	}
	if !found {
		t.Fatalf("Unknown=%v missing weirdo", m.Unknown)
	}
}

func TestParse_InvalidJSON(t *testing.T) {
	_, err := Parse([]byte(`{not json`), nil)
	if err == nil {
		t.Fatalf("expected error")
	}
}

func TestParse_UnknownProvidesWarns(t *testing.T) {
	data := []byte(`{
  "name":"x","version":"0.1.0","coda":"^0.1.0",
  "provides":{"notifications":{"slack":{}}}
}`)
	var warn bytes.Buffer
	if _, err := Parse(data, &warn); err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if !strings.Contains(warn.String(), `unknown provides key "notifications"`) {
		t.Fatalf("warn missing: %q", warn.String())
	}
}
