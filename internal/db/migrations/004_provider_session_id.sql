-- Add provider_session_id to sessions so coda can address downstream
-- provider methods (Stop/Deliver/Health/Output/Attach) by the
-- provider's native session ID rather than coda's internal ULID.
--
-- Provider.Start returns a string; before this migration it was
-- discarded and provider calls used coda's session ID, which made
-- correlation impossible for any provider with native session IDs
-- (CodaClaw: kit-default-01HXX, opencode: ses_..., etc.).
--
-- The column is NOT NULL DEFAULT '' so existing rows stay valid and
-- new rows fall through to coda's session ID until Set is called.

ALTER TABLE sessions ADD COLUMN provider_session_id TEXT NOT NULL DEFAULT '';
