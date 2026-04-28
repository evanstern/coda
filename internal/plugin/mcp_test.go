package plugin

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newMCPFixture(t *testing.T) *MCPServer {
	root := t.TempDir()
	binDir := filepath.Join(root, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	echo := filepath.Join(binDir, "echo")
	if err := os.WriteFile(echo, []byte("#!/bin/sh\ncat\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	plugins := []Plugin{{
		Root: root,
		Manifest: Manifest{
			Name: "demo",
			Provides: Provides{
				MCPTools: map[string]MCPTool{
					"echo": {
						Description: "echo back stdin",
						InputSchema: map[string]any{"type": "object"},
						Command:     []string{"bin/echo"},
					},
				},
			},
		},
	}}
	srv, err := NewMCPServer(plugins)
	if err != nil {
		t.Fatalf("NewMCPServer: %v", err)
	}
	return srv
}

func roundTrip(t *testing.T, srv *MCPServer, in string) []map[string]any {
	t.Helper()
	var out bytes.Buffer
	if err := srv.Serve(context.Background(), strings.NewReader(in), &out); err != nil {
		t.Fatalf("Serve: %v", err)
	}
	var got []map[string]any
	dec := json.NewDecoder(&out)
	for dec.More() {
		var m map[string]any
		if err := dec.Decode(&m); err != nil {
			t.Fatalf("decode: %v", err)
		}
		got = append(got, m)
	}
	return got
}

func TestMCP_Initialize(t *testing.T) {
	srv := newMCPFixture(t)
	resp := roundTrip(t, srv, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}`+"\n")
	if len(resp) != 1 {
		t.Fatalf("got %d responses, want 1", len(resp))
	}
	r := resp[0]
	if r["jsonrpc"] != "2.0" || r["id"].(float64) != 1 {
		t.Fatalf("envelope: %+v", r)
	}
	result := r["result"].(map[string]any)
	if result["protocolVersion"] != MCPProtocolVersion {
		t.Fatalf("protocolVersion=%v", result["protocolVersion"])
	}
	info := result["serverInfo"].(map[string]any)
	if info["name"] != MCPServerName {
		t.Fatalf("serverInfo.name=%v", info["name"])
	}
}

func TestMCP_ToolsList(t *testing.T) {
	srv := newMCPFixture(t)
	resp := roundTrip(t, srv, `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`+"\n")
	if len(resp) != 1 {
		t.Fatalf("got %d responses", len(resp))
	}
	tools := resp[0]["result"].(map[string]any)["tools"].([]any)
	if len(tools) != 1 {
		t.Fatalf("tools=%+v", tools)
	}
	first := tools[0].(map[string]any)
	if first["name"] != "echo" {
		t.Fatalf("tool name=%v", first["name"])
	}
	if first["description"] != "echo back stdin" {
		t.Fatalf("description=%v", first["description"])
	}
	schema, ok := first["inputSchema"].(map[string]any)
	if !ok {
		t.Fatalf("inputSchema missing or wrong type: %+v", first["inputSchema"])
	}
	if schema["type"] != "object" {
		t.Fatalf("inputSchema.type=%v", schema["type"])
	}
}

func TestMCP_ToolsList_DefaultsInputSchema(t *testing.T) {
	plugins := []Plugin{{
		Root: t.TempDir(),
		Manifest: Manifest{
			Name: "noschema",
			Provides: Provides{
				MCPTools: map[string]MCPTool{
					"bare": {
						Description: "tool with no declared schema",
						Command:     []string{"bin/whatever"},
					},
				},
			},
		},
	}}
	srv, err := NewMCPServer(plugins)
	if err != nil {
		t.Fatalf("NewMCPServer: %v", err)
	}
	resp := roundTrip(t, srv, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`+"\n")
	tools := resp[0]["result"].(map[string]any)["tools"].([]any)
	first := tools[0].(map[string]any)
	schema, ok := first["inputSchema"].(map[string]any)
	if !ok {
		t.Fatalf("inputSchema missing for tool with no declared schema: %+v", first)
	}
	if schema["type"] != "object" {
		t.Fatalf("default inputSchema.type=%v, want object", schema["type"])
	}
}

func TestMCP_ToolsCall(t *testing.T) {
	srv := newMCPFixture(t)
	resp := roundTrip(t, srv,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"hi":"there"}}}`+"\n")
	if len(resp) != 1 {
		t.Fatalf("got %d responses", len(resp))
	}
	result := resp[0]["result"].(map[string]any)
	if result["isError"].(bool) {
		t.Fatalf("isError=true: %+v", result)
	}
	content := result["content"].([]any)
	first := content[0].(map[string]any)
	text := first["text"].(string)
	if !strings.Contains(text, `"hi":"there"`) {
		t.Fatalf("text=%q", text)
	}
}

func TestMCP_ToolsCall_Unknown(t *testing.T) {
	srv := newMCPFixture(t)
	resp := roundTrip(t, srv,
		`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}`+"\n")
	if len(resp) != 1 {
		t.Fatalf("got %d responses", len(resp))
	}
	errObj := resp[0]["error"].(map[string]any)
	if int(errObj["code"].(float64)) != ErrInvalidParams {
		t.Fatalf("code=%v", errObj["code"])
	}
}

func TestMCP_ParseError(t *testing.T) {
	srv := newMCPFixture(t)
	resp := roundTrip(t, srv, "not json\n")
	if len(resp) != 1 {
		t.Fatalf("got %d responses", len(resp))
	}
	errObj := resp[0]["error"].(map[string]any)
	if int(errObj["code"].(float64)) != ErrParse {
		t.Fatalf("code=%v", errObj["code"])
	}
	id, ok := resp[0]["id"]
	if !ok {
		t.Fatalf("parse-error response must include id field per JSON-RPC 2.0; missing")
	}
	if id != nil {
		t.Fatalf("parse-error id should be null, got %v", id)
	}
}

func TestMCP_MethodNotFound(t *testing.T) {
	srv := newMCPFixture(t)
	resp := roundTrip(t, srv, `{"jsonrpc":"2.0","id":5,"method":"prompts/list"}`+"\n")
	if len(resp) != 1 {
		t.Fatalf("got %d responses", len(resp))
	}
	errObj := resp[0]["error"].(map[string]any)
	if int(errObj["code"].(float64)) != ErrMethodNotFound {
		t.Fatalf("code=%v", errObj["code"])
	}
}

func TestMCP_NotificationNoResponse(t *testing.T) {
	srv := newMCPFixture(t)
	resp := roundTrip(t, srv, `{"jsonrpc":"2.0","method":"notifications/initialized"}`+"\n")
	if len(resp) != 0 {
		t.Fatalf("expected no response for notification, got %+v", resp)
	}
}

func TestMCP_DuplicateToolName(t *testing.T) {
	plugins := []Plugin{
		{Root: t.TempDir(), Manifest: Manifest{Name: "a", Provides: Provides{MCPTools: map[string]MCPTool{"x": {Command: []string{"true"}}}}}},
		{Root: t.TempDir(), Manifest: Manifest{Name: "b", Provides: Provides{MCPTools: map[string]MCPTool{"x": {Command: []string{"true"}}}}}},
	}
	if _, err := NewMCPServer(plugins); err == nil {
		t.Fatal("expected duplicate-tool error")
	}
}
