package plugin

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"sort"
)

// JSON-RPC 2.0 error codes used by the MCP server.
const (
	ErrParse          = -32700
	ErrInvalidRequest = -32600
	ErrMethodNotFound = -32601
	ErrInvalidParams  = -32602
	ErrInternal       = -32603
)

// MCPProtocolVersion is the version reported by initialize. Mirrors
// the MCP 2024-11-05 protocol level which is what most clients
// negotiate today.
const MCPProtocolVersion = "2024-11-05"

// MCPServerName and MCPServerVersion identify the host in the
// initialize response.
const (
	MCPServerName    = "coda"
	MCPServerVersion = "0.1.0"
)

// MCPServer is a stdio JSON-RPC 2.0 server that exposes
// plugin-declared tools through the three Model Context Protocol
// methods initialize, tools/list, and tools/call.
type MCPServer struct {
	Tools []MCPToolEntry
}

// MCPToolEntry is a public summary of a registered MCP tool.
type MCPToolEntry struct {
	Name        string         `json:"name"`
	Description string         `json:"description,omitempty"`
	InputSchema map[string]any `json:"inputSchema,omitempty"`
	Plugin      string         `json:"-"`
	Command     []string       `json:"-"`
	Root        string         `json:"-"`
}

// NewMCPServer constructs a server from the loaded plugins. A
// duplicate tool name across plugins is an error.
func NewMCPServer(plugins []Plugin) (*MCPServer, error) {
	seen := map[string]string{}
	tools := make([]MCPToolEntry, 0)
	for _, p := range plugins {
		names := make([]string, 0, len(p.Manifest.Provides.MCPTools))
		for n := range p.Manifest.Provides.MCPTools {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, name := range names {
			if existing, ok := seen[name]; ok {
				return nil, fmt.Errorf("plugin %s: mcp tool %q already registered by plugin %s", p.Manifest.Name, name, existing)
			}
			seen[name] = p.Manifest.Name
			t := p.Manifest.Provides.MCPTools[name]
			if len(t.Command) == 0 {
				return nil, fmt.Errorf("plugin %s: mcp tool %q: command is required", p.Manifest.Name, name)
			}
			tools = append(tools, MCPToolEntry{
				Name:        name,
				Description: t.Description,
				InputSchema: t.InputSchema,
				Plugin:      p.Manifest.Name,
				Command:     append([]string(nil), t.Command...),
				Root:        p.Root,
			})
		}
	}
	sort.Slice(tools, func(i, j int) bool { return tools[i].Name < tools[j].Name })
	return &MCPServer{Tools: tools}, nil
}

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

// Serve reads newline-delimited JSON-RPC 2.0 requests from in,
// writes responses to out. It returns when in is exhausted or ctx
// is cancelled.
func (s *MCPServer) Serve(ctx context.Context, in io.Reader, out io.Writer) error {
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	enc := json.NewEncoder(out)
	for scanner.Scan() {
		if err := ctx.Err(); err != nil {
			return err
		}
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		resp := s.handle(ctx, line)
		if resp == nil {
			continue
		}
		if err := enc.Encode(resp); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func (s *MCPServer) handle(ctx context.Context, line []byte) *rpcResponse {
	var req rpcRequest
	if err := json.Unmarshal(line, &req); err != nil {
		return &rpcResponse{JSONRPC: "2.0", ID: json.RawMessage("null"), Error: &rpcError{Code: ErrParse, Message: "parse error: " + err.Error()}}
	}
	if req.JSONRPC != "2.0" {
		id := req.ID
		if len(id) == 0 {
			id = json.RawMessage("null")
		}
		return &rpcResponse{JSONRPC: "2.0", ID: id, Error: &rpcError{Code: ErrInvalidRequest, Message: "jsonrpc must be \"2.0\""}}
	}
	// JSON-RPC 2.0 notifications (no id field) get no response. An
	// explicit `"id": null` is a request, not a notification — but
	// MCP tooling never sends that, so treating both as notifications
	// is acceptable for now.
	if len(req.ID) == 0 {
		return nil
	}
	switch req.Method {
	case "initialize":
		return s.handleInitialize(req)
	case "tools/list":
		return s.handleToolsList(req)
	case "tools/call":
		return s.handleToolsCall(ctx, req)
	default:
		return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: ErrMethodNotFound, Message: "method not found: " + req.Method}}
	}
}

func (s *MCPServer) handleInitialize(req rpcRequest) *rpcResponse {
	result := map[string]any{
		"protocolVersion": MCPProtocolVersion,
		"capabilities": map[string]any{
			"tools": map[string]any{},
		},
		"serverInfo": map[string]any{
			"name":    MCPServerName,
			"version": MCPServerVersion,
		},
	}
	return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: result}
}

func (s *MCPServer) handleToolsList(req rpcRequest) *rpcResponse {
	out := make([]map[string]any, 0, len(s.Tools))
	for _, t := range s.Tools {
		entry := map[string]any{"name": t.Name}
		if t.Description != "" {
			entry["description"] = t.Description
		}
		// MCP requires inputSchema on every tool. Default to an
		// empty object schema when the manifest is silent so strict
		// clients (e.g. opencode) don't reject the tools/list reply.
		if t.InputSchema != nil {
			entry["inputSchema"] = t.InputSchema
		} else {
			entry["inputSchema"] = map[string]any{"type": "object"}
		}
		out = append(out, entry)
	}
	return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{"tools": out}}
}

func (s *MCPServer) handleToolsCall(ctx context.Context, req rpcRequest) *rpcResponse {
	var params struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if len(req.Params) > 0 {
		if err := json.Unmarshal(req.Params, &params); err != nil {
			return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: ErrInvalidParams, Message: "invalid params: " + err.Error()}}
		}
	}
	if params.Name == "" {
		return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: ErrInvalidParams, Message: "tools/call requires \"name\""}}
	}
	tool := s.findTool(params.Name)
	if tool == nil {
		return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: ErrInvalidParams, Message: "unknown tool: " + params.Name}}
	}
	args := params.Arguments
	if len(args) == 0 {
		args = []byte("{}")
	}
	stdout, callErr := tool.run(ctx, args)
	if callErr != nil {
		result := map[string]any{
			"content": []map[string]any{{"type": "text", "text": callErr.Error()}},
			"isError": true,
		}
		return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: result}
	}
	result := map[string]any{
		"content": []map[string]any{{"type": "text", "text": string(stdout)}},
		"isError": false,
	}
	return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: result}
}

func (s *MCPServer) findTool(name string) *MCPToolEntry {
	for i := range s.Tools {
		if s.Tools[i].Name == name {
			return &s.Tools[i]
		}
	}
	return nil
}

func (t *MCPToolEntry) run(ctx context.Context, stdin []byte) ([]byte, error) {
	if len(t.Command) == 0 {
		return nil, errors.New("tool command empty")
	}
	argv := append([]string(nil), t.Command...)
	if !filepath.IsAbs(argv[0]) {
		argv[0] = filepath.Join(t.Root, argv[0])
	}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Stdin = bytes.NewReader(stdin)
	var out, errBuf bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		msg := errBuf.String()
		if msg == "" {
			msg = out.String()
		}
		return nil, fmt.Errorf("tool %s: %w: %s", t.Name, err, msg)
	}
	return out.Bytes(), nil
}
