-- chat.db. Tables are created if missing; there is no migration framework. Every row's `json`
-- is the Synara wire shape of what it holds, so new Synara fields need no column.

CREATE TABLE IF NOT EXISTS threads (
  id          TEXT PRIMARY KEY,
  -- A Cascade project id, or '' for a chat that belongs to no project.
  project_id  TEXT NOT NULL,
  deleted     INTEGER NOT NULL DEFAULT 0,
  updated_at  TEXT NOT NULL,
  json        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS threads_by_project ON threads (project_id, deleted, updated_at);

CREATE TABLE IF NOT EXISTS messages (
  thread_id  TEXT NOT NULL REFERENCES threads (id) ON DELETE CASCADE,
  id         TEXT NOT NULL,
  ordinal    INTEGER NOT NULL,
  json       TEXT NOT NULL,
  PRIMARY KEY (thread_id, id)
);

CREATE TABLE IF NOT EXISTS activities (
  thread_id  TEXT NOT NULL REFERENCES threads (id) ON DELETE CASCADE,
  id         TEXT NOT NULL,
  ordinal    INTEGER NOT NULL,
  json       TEXT NOT NULL,
  PRIMARY KEY (thread_id, id)
);

CREATE TABLE IF NOT EXISTS proposed_plans (
  thread_id  TEXT NOT NULL REFERENCES threads (id) ON DELETE CASCADE,
  id         TEXT NOT NULL,
  ordinal    INTEGER NOT NULL,
  json       TEXT NOT NULL,
  PRIMARY KEY (thread_id, id)
);

CREATE TABLE IF NOT EXISTS checkpoints (
  thread_id  TEXT NOT NULL REFERENCES threads (id) ON DELETE CASCADE,
  id         TEXT NOT NULL,
  ordinal    INTEGER NOT NULL,
  json       TEXT NOT NULL,
  PRIMARY KEY (thread_id, id)
);

-- Synara `provider_session_runtime`: what picks a CLI's conversation up again.
CREATE TABLE IF NOT EXISTS provider_sessions (
  thread_id      TEXT PRIMARY KEY REFERENCES threads (id) ON DELETE CASCADE,
  provider       TEXT NOT NULL,
  resume_cursor  TEXT,
  updated_at     TEXT NOT NULL
);

-- The last event `sequence` the engine numbered for each thread, so numbering continues after a
-- restart.
CREATE TABLE IF NOT EXISTS thread_sequences (
  thread_id  TEXT PRIMARY KEY,
  sequence   INTEGER NOT NULL
);
