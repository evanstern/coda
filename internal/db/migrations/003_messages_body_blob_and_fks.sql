-- Recreate messages with:
--   * body as BLOB (was TEXT) so non-UTF-8 payloads round-trip cleanly
--   * sender + recipient FKs to agents(name) ON DELETE RESTRICT to
--     prevent orphan rows and silent agent-deletion data loss.
--
-- foreign_keys is OFF for the duration of the migration (see
-- internal/db/migrations.go); foreign_key_check inside the tx will
-- catch any orphaned rows and roll back if the existing data is bad.

CREATE TABLE messages_new (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  sender       TEXT NOT NULL REFERENCES agents(name) ON DELETE RESTRICT,
  recipient    TEXT NOT NULL REFERENCES agents(name) ON DELETE RESTRICT,
  type         TEXT NOT NULL,
  body         BLOB NOT NULL,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  delivered_at TEXT,
  acked_at     TEXT
);

INSERT INTO messages_new (id, sender, recipient, type, body, created_at, delivered_at, acked_at)
SELECT id, sender, recipient, type, CAST(body AS BLOB), created_at, delivered_at, acked_at
FROM messages;

DROP INDEX IF EXISTS messages_recipient_unacked;
DROP INDEX IF EXISTS messages_recipient_undelivered;
DROP TABLE messages;
ALTER TABLE messages_new RENAME TO messages;

CREATE INDEX messages_recipient_unacked
  ON messages(recipient)
  WHERE acked_at IS NULL;

CREATE INDEX messages_recipient_undelivered
  ON messages(recipient)
  WHERE delivered_at IS NULL;
