const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const {
  StdioServerTransport,
} = require("@modelcontextprotocol/sdk/server/stdio.js");
const { execFile } = require("child_process");
const { promisify } = require("util");
const path = require("path");
const fs = require("fs");
const z = require("zod");

const execFileAsync = promisify(execFile);

const CODA_DIR = process.env.CODA_DIR || path.resolve(__dirname, "..");
const SHELL = "/bin/bash";

async function runCoda(args, { cwd, timeout = 15000 } = {}) {
  const script = [
    `source "${CODA_DIR}/shell-functions.sh"`,
    `coda ${args.map(shellEscape).join(" ")}`,
  ].join("\n");

  try {
    const { stdout, stderr } = await execFileAsync(
      SHELL,
      ["-c", script],
      {
        cwd: cwd || process.env.HOME,
        timeout,
        env: {
          ...process.env,
          AUTO_ATTACH_TMUX: "false",
          TERM: "dumb",
        },
      }
    );
    return { stdout: stdout.trim(), stderr: stderr.trim(), exitCode: 0 };
  } catch (err) {
    return {
      stdout: (err.stdout || "").trim(),
      stderr: (err.stderr || err.message || "").trim(),
      exitCode: err.code || 1,
    };
  }
}

function shellEscape(arg) {
  return "'" + arg.replace(/'/g, "'\\''" ) + "'";
}

function textResult(text) {
  return { content: [{ type: "text", text }] };
}

function formatResult({ stdout, stderr, exitCode }) {
  let text = stdout || "";
  if (stderr) text += (text ? "\n\n" : "") + `stderr: ${stderr}`;
  if (exitCode !== 0) text += (text ? "\n" : "") + `exit code: ${exitCode}`;
  return textResult(text || "(no output)");
}

const server = new McpServer(
  { name: "coda", version: "1.0.0" },
  {
    capabilities: { logging: {} },
    instructions: [
      "This server provides tools for managing coda sessions, projects, and features.",
      "Coda manages OpenCode AI agent sessions in tmux with git worktree isolation.",
      "Use coda_ls to see running sessions, coda_project_ls to see projects,",
      "coda_feature_ls to see worktrees, and the other tools to manage them.",
    ].join(" "),
  }
);

// ── Core tools (always available) ───────────────────────────────────

server.tool(
  "coda_ls",
  "List all active coda tmux sessions with window count and creation time",
  {},
  async () => formatResult(await runCoda(["ls"]))
);

server.tool(
  "coda_project_ls",
  "List all coda-managed projects in the projects directory",
  {},
  async () => formatResult(await runCoda(["project", "ls"]))
);

server.tool(
  "coda_feature_ls",
  "List all git worktrees for the current project. Must specify a project directory.",
  { project_dir: z.string().describe("Absolute path to a project worktree directory (e.g. ~/projects/myapp/main)") },
  async ({ project_dir }) =>
    formatResult(await runCoda(["feature", "ls"], { cwd: project_dir }))
);

server.tool(
  "coda_feature_start",
  "Create a new git worktree on a feature branch and open an OpenCode session for it. Creates branch from base (default: main).",
  {
    branch: z.string().describe("Branch name for the new feature"),
    base: z.string().optional().describe("Base branch to create from (default: main/master)"),
    project: z.string().optional().describe("Project name (auto-detected from project_dir if omitted)"),
    project_dir: z.string().describe("Absolute path to a project worktree directory to run from"),
  },
  async ({ branch, base, project, project_dir }) => {
    const args = ["feature", "start", branch];
    if (base) args.push(base);
    if (project) args.push(project);
    return formatResult(await runCoda(args, { cwd: project_dir, timeout: 30000 }));
  }
);

server.tool(
  "coda_feature_done",
  "Tear down a feature: kill tmux session, remove worktree, delete branch. WARNING: Deletes the branch regardless of merge status.",
  {
    branch: z.string().describe("Branch name to tear down"),
    project: z.string().optional().describe("Project name (auto-detected from project_dir if omitted)"),
    project_dir: z.string().describe("Absolute path to a project worktree directory to run from"),
  },
  async ({ branch, project, project_dir }) => {
    const args = ["feature", "done", branch];
    if (project) args.push(project);
    return formatResult(await runCoda(args, { cwd: project_dir, timeout: 30000 }));
  }
);

server.tool(
  "coda_feature_finish",
  "Tear down the current feature branch (detected from working directory). Agent-safe: runs teardown in background. Use --force to skip uncommitted changes check.",
  {
    project_dir: z.string().describe("Absolute path to the feature's worktree directory"),
    force: z.boolean().optional().describe("Skip uncommitted changes check"),
  },
  async ({ project_dir, force }) => {
    const args = ["feature", "finish"];
    if (force) args.push("--force");
    return formatResult(await runCoda(args, { cwd: project_dir, timeout: 30000 }));
  }
);

server.tool(
  "coda_project_clone",
  "Clone a git repository as a coda project using the bare repo + worktree pattern",
  {
    repo_url: z.string().describe("Git repository URL (SSH or HTTPS)"),
    name: z.string().optional().describe("Custom project name (default: derived from repo URL)"),
  },
  async ({ repo_url, name }) => {
    const args = ["project", "start", "--repo", repo_url];
    if (name) args.push(name);
    return formatResult(await runCoda(args, { timeout: 60000 }));
  }
);

server.tool(
  "coda_project_create",
  "Create a new private GitHub repository and set it up as a coda project with bare repo + worktree pattern",
  {
    name: z.string().describe("Repository/project name"),
    message: z.string().optional().describe("Initial context written to AGENTS.md for AI coding agents"),
  },
  async ({ name, message }) => {
    const args = ["project", "start", "--new", name];
    if (message) args.push("-m", message);
    return formatResult(await runCoda(args, { timeout: 60000 }));
  }
);

server.tool(
  "coda_project_workon",
  "Open a project session, creating a worktree if needed",
  {
    name: z.string().describe("Project name"),
    branch: z.string().optional().describe("Branch to work on (default: main/master)"),
  },
  async ({ name, branch }) => {
    const args = ["project", "workon", name];
    if (branch) args.push(branch);
    return formatResult(await runCoda(args, { timeout: 30000 }));
  }
);

server.tool(
  "coda_project_close",
  "Close all tmux sessions for the current project. Optionally delete the project folder.",
  {
    project_dir: z.string().describe("Absolute path to a project worktree directory"),
    delete: z.boolean().optional().describe("Also delete the project folder and all worktrees"),
  },
  async ({ project_dir, delete: del }) => {
    const args = ["project", "close"];
    if (del) args.push("--delete");
    return formatResult(await runCoda(args, { cwd: project_dir, timeout: 30000 }));
  }
);

server.tool(
  "coda_layout_ls",
  "List available tmux layouts",
  {},
  async () => formatResult(await runCoda(["layout", "ls"]))
);

server.tool(
  "coda_layout_show",
  "Show the contents of a tmux layout file",
  { name: z.string().describe("Layout name") },
  async ({ name }) => formatResult(await runCoda(["layout", "show", name]))
);

server.tool(
  "coda_help",
  "Show the coda CLI help summary with all available commands",
  {},
  async () => formatResult(await runCoda(["help"]))
);

// ── Dynamic plugin tools ────────────────────────────────────────────

function pluginNameFromUrl(url) {
  let name = path.basename(url);
  if (name.endsWith(".git")) name = name.slice(0, -4);
  return name;
}

function buildZodSchema(params) {
  if (!params || Object.keys(params).length === 0) return {};
  const schema = {};
  for (const [name, def] of Object.entries(params)) {
    const paramType = def.type || "string";
    let field;
    if (paramType === "boolean") {
      field = z.boolean();
    } else if (paramType === "cwd") {
      field = z.string();
    } else {
      field = z.string();
    }
    if (def.description) field = field.describe(def.description);
    if (def.optional) field = field.optional();
    schema[name] = field;
  }
  return schema;
}

function buildHandler(command, params) {
  return async (args) => {
    const cmdArgs = [...command];
    let cwd;

    if (params) {
      for (const [name, def] of Object.entries(params)) {
        const val = args[name];
        if (val === undefined || val === null) continue;

        if (def.type === "cwd") {
          cwd = val;
        } else if (def.type === "boolean") {
          if (val) cmdArgs.push(`--${name}`);
        } else {
          cmdArgs.push(`--${name}`, String(val));
        }
      }
    }

    return formatResult(await runCoda(cmdArgs, { cwd }));
  };
}

function loadPluginTools() {
  const configPath = process.env.CODA_CONFIG_PATH
    || path.join(process.env.HOME, ".config", "coda", "config.json");
  const pluginsDir = process.env.CODA_PLUGINS_DIR
    || path.join(process.env.HOME, ".config", "coda", "plugins");

  let config;
  try {
    config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch {
    return;
  }

  const plugins = config.plugins;
  if (!plugins || typeof plugins !== "object") return;

  for (const [url, entry] of Object.entries(plugins)) {
    if (entry.enabled === false) continue;

    const name = pluginNameFromUrl(url);
    if (!name) continue;

    const pluginJsonPath = path.join(pluginsDir, name, "plugin.json");
    let pluginJson;
    try {
      pluginJson = JSON.parse(fs.readFileSync(pluginJsonPath, "utf8"));
    } catch {
      continue;
    }

    const mcpTools = pluginJson.provides && pluginJson.provides.mcp_tools;
    if (!mcpTools || typeof mcpTools !== "object") continue;

    for (const [toolName, toolDef] of Object.entries(mcpTools)) {
      const schema = buildZodSchema(toolDef.params);
      const handler = buildHandler(toolDef.command, toolDef.params);
      server.tool(toolName, toolDef.description, schema, handler);
    }
  }
}

loadPluginTools();

// ── Start ───────────────────────────────────────────────────────────

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("coda MCP server running on stdio");
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
