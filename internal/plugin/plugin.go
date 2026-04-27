// Package plugin implements coda's plugin host: manifest parsing,
// discovery, subprocess providers, hook dispatch, command registration,
// and the stdio MCP server. It is the unblocking primitive that makes
// the otherwise empty ProviderRegistry usable.
//
// A plugin lives in a directory under $XDG_CONFIG_HOME/coda/plugins
// (overridable via $CODA_PLUGINS_DIR) and ships a plugin.json
// manifest. Manifests declare four optional contribution kinds:
// commands, hooks, providers, and mcp_tools. Each contribution has
// an executable artifact in the plugin dir; coda dispatches via
// os/exec with explicit argv slices (no shell sourcing).
package plugin

// Plugin is a parsed manifest plus the absolute path to the plugin's
// root directory. Loader returns []Plugin; consumers (provider
// registry, command dispatcher, MCP server, hook runner) all key off
// of these values.
type Plugin struct {
	Manifest Manifest
	Root     string
}
