CREATE TABLE IF NOT EXISTS logs (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, category TEXT NOT NULL DEFAULT 'event',
  level TEXT NOT NULL DEFAULT 'info', type TEXT, payload TEXT, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_logs_category ON logs(category, seq);
CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level, seq);
CREATE TABLE IF NOT EXISTS automation_runs (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, automation_id TEXT NOT NULL, event_key TEXT NOT NULL DEFAULT '',
  mode TEXT NOT NULL, status TEXT NOT NULL, subject TEXT NOT NULL DEFAULT '', trace TEXT NOT NULL DEFAULT '{}',
  started_at TEXT NOT NULL, finished_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_automation_runs ON automation_runs(automation_id, seq);
