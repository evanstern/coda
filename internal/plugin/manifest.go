package plugin

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"sort"
)

// Manifest is the parsed shape of a v3 plugin.json. Required fields
// are Name, Version, and Coda. The four provides sections are all
// optional.
type Manifest struct {
	Name        string       `json:"name"`
	Version     string       `json:"version"`
	Coda        string       `json:"coda"`
	Description string       `json:"description,omitempty"`
	Provides    Provides     `json:"provides,omitempty"`
	Deps        Dependencies `json:"dependencies,omitempty"`
	Install     string       `json:"install,omitempty"`
	Unknown     []string     `json:"-"`
}

// Provides groups the four kinds of contributions a plugin can ship.
type Provides struct {
	Commands  map[string]CommandSpec  `json:"commands,omitempty"`
	Hooks     map[string][]string     `json:"hooks,omitempty"`
	Providers map[string]ProviderSpec `json:"providers,omitempty"`
	MCPTools  map[string]MCPTool      `json:"mcp_tools,omitempty"`
}

// CommandSpec is the manifest shape of a plugin-contributed CLI
// command. Exec is a path relative to the plugin's root dir.
type CommandSpec struct {
	Description string `json:"description,omitempty"`
	Exec        string `json:"exec"`
}

// ProviderSpec is the manifest shape of a plugin-contributed
// session.Provider. Exec is a path relative to the plugin's root dir.
type ProviderSpec struct {
	Exec string `json:"exec"`
}

// MCPTool is the manifest shape of a plugin-contributed MCP tool.
// Command is the argv slice the host will exec when the tool is
// invoked; the first element is resolved relative to the plugin root
// if it is not absolute.
type MCPTool struct {
	Description string         `json:"description,omitempty"`
	InputSchema map[string]any `json:"inputSchema,omitempty"`
	Command     []string       `json:"command"`
}

// Dependencies is advisory only — install scripts enforce; the host
// does not check.
type Dependencies struct {
	System []string `json:"system,omitempty"`
	Go     string   `json:"go,omitempty"`
	NPM    []string `json:"npm,omitempty"`
}

// knownTopLevel is the set of recognized top-level keys. Anything
// else triggers a warning when Parse is given a non-nil warn writer.
var knownTopLevel = map[string]struct{}{
	"name":         {},
	"version":      {},
	"coda":         {},
	"description":  {},
	"provides":     {},
	"dependencies": {},
	"install":      {},
}

// knownProvides is the set of recognized provides.* keys.
var knownProvides = map[string]struct{}{
	"commands":  {},
	"hooks":     {},
	"providers": {},
	"mcp_tools": {},
}

// Parse decodes a plugin.json byte slice into a Manifest. Required
// keys (name, version, coda) must be present and non-empty. Unknown
// top-level keys are recorded on Manifest.Unknown and, if warn is
// non-nil, also written there as "warn: ..." lines.
func Parse(data []byte, warn io.Writer) (Manifest, error) {
	var raw map[string]json.RawMessage
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&raw); err != nil {
		return Manifest{}, fmt.Errorf("decode plugin.json: %w", err)
	}
	var m Manifest
	if err := json.Unmarshal(data, &m); err != nil {
		return Manifest{}, fmt.Errorf("decode plugin.json: %w", err)
	}
	if m.Name == "" {
		return Manifest{}, fmt.Errorf("manifest: missing required field %q", "name")
	}
	if m.Version == "" {
		return Manifest{}, fmt.Errorf("manifest: missing required field %q", "version")
	}
	if m.Coda == "" {
		return Manifest{}, fmt.Errorf("manifest: missing required field %q", "coda")
	}
	unknown := make([]string, 0)
	for k := range raw {
		if _, ok := knownTopLevel[k]; !ok {
			unknown = append(unknown, k)
		}
	}
	sort.Strings(unknown)
	m.Unknown = unknown
	if warn != nil {
		for _, k := range unknown {
			fmt.Fprintf(warn, "warn: plugin %s: unknown manifest key %q\n", m.Name, k)
		}
		if pr, ok := raw["provides"]; ok {
			var pmap map[string]json.RawMessage
			if err := json.Unmarshal(pr, &pmap); err == nil {
				keys := make([]string, 0, len(pmap))
				for k := range pmap {
					if _, ok := knownProvides[k]; !ok {
						keys = append(keys, k)
					}
				}
				sort.Strings(keys)
				for _, k := range keys {
					fmt.Fprintf(warn, "warn: plugin %s: unknown provides key %q\n", m.Name, k)
				}
			}
		}
	}
	return m, nil
}
