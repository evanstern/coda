CREATE TABLE agents (
  name       TEXT PRIMARY KEY,
  provider   TEXT,
  config_dir TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE sessions (
  id          TEXT PRIMARY KEY,
  agent_name  TEXT NOT NULL REFERENCES agents(name) ON DELETE CASCADE,
  provider    TEXT NOT NULL,
  state       TEXT NOT NULL DEFAULT 'created',
  started_at  TEXT,
  stopped_at  TEXT,
  stop_reason TEXT
);

-- Only one non-stopped session per agent (enforced at code AND DB level).
CREATE UNIQUE INDEX sessions_one_active_per_agent
  ON sessions(agent_name)
  WHERE state != 'stopped';

CREATE INDEX sessions_agent ON sessions(agent_name);
