CREATE TABLE messages (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  sender       TEXT NOT NULL,
  recipient    TEXT NOT NULL,
  type         TEXT NOT NULL,
  body         TEXT NOT NULL,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  delivered_at TEXT,
  acked_at     TEXT
);

CREATE INDEX messages_recipient_unacked
  ON messages(recipient)
  WHERE acked_at IS NULL;

CREATE INDEX messages_recipient_undelivered
  ON messages(recipient)
  WHERE delivered_at IS NULL;
