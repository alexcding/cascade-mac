CREATE TABLE IF NOT EXISTS logs (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, category TEXT NOT NULL DEFAULT 'event',
  level TEXT NOT NULL DEFAULT 'info', type TEXT, payload TEXT, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_logs_category ON logs(category, seq);
CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level, seq);
