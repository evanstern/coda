# MCP tool contract

`coda mcp serve` runs a stdio JSON-RPC 2.0 server that exposes
plugin-declared tools through the Model Context Protocol. The server
implements three methods:

- `initialize` — returns server capabilities and protocol version
- `tools/list` — returns the registered tools
- `tools/call` — dispatches to a plugin's command, with JSON
  arguments on stdin and stdout returned as text content

Notifications (no `id`) are accepted and ignored. Other methods
return a JSON-RPC `-32601 method not found` error.

## Tool registration

In a plugin's `plugin.json`:

```json
{
  "provides": {
    "mcp_tools": {
      "echo": {
        "description": "echo back its input",
        "inputSchema": {"type": "object"},
        "command": ["bin/echo"]
      }
    }
  }
}
```

`command` is the argv used to invoke the tool. The first element is
resolved relative to the plugin root if it is not absolute.
Subsequent elements are passed as additional arguments verbatim.

## Invocation flow

When a client sends:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}
```

The server:

1. Looks up the tool by name. Unknown tool → `-32602 invalid params`.
2. Spawns the tool process with the manifest's `command` argv.
3. Writes the `arguments` JSON object to the tool's stdin.
4. Captures stdout. On success, returns
   `{"content":[{"type":"text","text":"<stdout>"}],"isError":false}`.
5. On non-zero exit, returns the same shape with `"isError":true`
   and the error text in the content.

## Wire format

Newline-delimited JSON. One JSON object per line on stdin and
stdout. Other framings (HTTP, content-length-prefixed) are out of
scope for this card.

## Server identity

`initialize` returns:

```json
{
  "protocolVersion": "2024-11-05",
  "capabilities": {"tools": {}},
  "serverInfo": {"name": "coda", "version": "0.1.0"}
}
```

## Standard error codes

| code     | meaning                                             |
|----------|-----------------------------------------------------|
| `-32700` | parse error (malformed JSON on the wire)           |
| `-32600` | invalid request (jsonrpc field missing or wrong)   |
| `-32601` | method not found                                   |
| `-32602` | invalid params (missing `name`, unknown tool, …)   |
| `-32603` | internal server error                              |

## Out of scope

The card ships only the three methods above. Prompts, resources,
sampling, completion, logging, and other MCP methods are
follow-ups.
